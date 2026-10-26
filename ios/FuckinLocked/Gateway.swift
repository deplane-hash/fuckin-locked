import Foundation
import CryptoKit
import Security

enum ConnectionError: Error { case unavailable, invalidResponse }

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private func makeGatewaySession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
}

struct Admission: Decodable {
    let admission_id: String
    let user_id: String
    let device_id: String
    let state: String
}
struct BootstrapResult: Decodable { let user_id: String; let device_id: String }
struct AccountProfile: Decodable {
    let user_id: String
    let device_id: String
    let name: String
    let username: String
}

struct Challenge: Decodable { let challenge: String }
struct SessionToken: Decodable { let token: String }
struct Invitation: Decodable { let code: String }
struct Person: Decodable, Identifiable { let id: String; let name: String; let username: String }
struct PeopleResponse: Decodable { let people: [Person] }
struct PendingAdmission: Decodable, Identifiable { let id: String; let name: String; let username: String; let created_at: Int }
struct AdmissionsResponse: Decodable { let pending: [PendingAdmission] }
struct DeviceInfo: Decodable, Identifiable { let id: String; let state: String; let created_at: Int }
struct DevicesResponse: Decodable { let devices: [DeviceInfo] }
struct RoomCreated: Decodable { let room_id: String }
struct RoomDevice: Decodable { let id: String; let user_id: String }
struct RoomDevices: Decodable { let devices: [RoomDevice] }
struct CallTURN: Decodable {
    let url: String
    let username: String
    let credential: String

    func validateRoute(expectedHost: String) throws {
        guard !expectedHost.isEmpty, !expectedHost.contains("REPLACE_"),
              url.lowercased().hasPrefix("turns:"),
              let parsed = URLComponents(string: "https://" + String(url.dropFirst(6))),
              parsed.host?.lowercased() == expectedHost.lowercased(),
              parsed.user == nil, parsed.password == nil, parsed.path.isEmpty,
              parsed.fragment == nil, parsed.query == "transport=tcp",
              parsed.port == nil || (1...65535).contains(parsed.port!),
              !username.isEmpty, !credential.isEmpty else {
            throw ConnectionError.unavailable
        }
    }
}
struct RoomMember: Decodable, Identifiable {
    let id: String
    let name: String
    let username: String
}
struct RoomInfo: Decodable, Identifiable {
    let id: String
    let members: [RoomMember]
    let is_group: Bool?
}
struct RoomsResponse: Decodable { let rooms: [RoomInfo] }
struct RelayEnvelope: Codable {
    let id: String
    let room_id: String
    let sender_device: String
    let sender_user_id: String
    let kind: String
    let ciphertext: Data
    let created_at: Int
}
struct RelayEnvelopes: Decodable { let envelopes: [RelayEnvelope] }
struct RelayPrekeyBundle: Codable {
    let device_id: String
    let registration_id: UInt32
    let device_number: UInt32
    let identity_key: Data
    let signed_prekey_id: UInt32
    let signed_prekey: Data
    let signed_prekey_signature: Data
    let one_time_prekey_id: UInt32
    let one_time_prekey: Data
    let kyber_prekey_id: UInt32
    let kyber_prekey: Data
    let kyber_prekey_signature: Data
}

@MainActor final class Gateway: ObservableObject {
    @Published private(set) var connected = false
    private let baseOverride: URL?
    private let identityAccount: String
    private let diagnostics: ((Int) -> Void)?
    private var token: String?
    private var generation = 0
    private var session = makeGatewaySession()

    init(baseURL: URL? = nil, session: URLSession? = nil,
         identityAccount: String = DeviceIdentity.defaultAccount,
         diagnostics: ((Int) -> Void)? = nil) {
        baseOverride = baseURL
        self.identityAccount = identityAccount
        self.diagnostics = diagnostics
        if let session { self.session = session }
    }

    private var base: URL? {
        let configured = baseOverride?.absoluteString
            ?? (Bundle.main.object(forInfoDictionaryKey: "FLGatewayURL") as? String)
        guard let value = configured,
              let url = URL(string: value), url.scheme == "https",
              let host = url.host, host != "REPLACE_WITH_GATEWAY_HOST",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return url
    }

    // Keep any configured path prefix (for example /fuckin-locked/) when
    // constructing service endpoints. URL(string:relativeTo:) treats a
    // leading slash as an origin-root path and would bypass that prefix.
    private func endpoint(_ path: String) -> URL? {
        guard let base, path.hasPrefix("/") else { return nil }
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/" + ([prefix, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        return components?.url
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let started = generation
        guard let url = endpoint(path) else { throw ConnectionError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            diagnostics?((response as? HTTPURLResponse)?.statusCode ?? -1)
            guard started == generation else { throw ConnectionError.unavailable }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ConnectionError.unavailable
            }
            connected = true
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            diagnostics?((error as NSError).code)
            if started == generation { connected = false }
            throw ConnectionError.unavailable
        }
    }

    func enroll(code: String, name: String, username: String) async throws -> Admission {
        let key = try DeviceIdentity.getOrCreate(account: identityAccount)
        let result: Admission = try await request("/v1/admissions", method: "POST", body: [
            "code": code, "name": name, "username": username,
            "public_key": key.publicKey.rawRepresentation.base64EncodedString()
        ])
        return result
    }

    func bootstrap(token: String, name: String, username: String) async throws -> BootstrapResult {
        let started = generation
        let key = try DeviceIdentity.getOrCreate(account: identityAccount)
        guard let url = endpoint("/v1/bootstrap") else {
            throw ConnectionError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Bootstrap-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "username": username,
            "public_key": key.publicKey.rawRepresentation.base64EncodedString()
        ])
        do {
            let (data, response) = try await session.data(for: request)
            diagnostics?((response as? HTTPURLResponse)?.statusCode ?? -1)
            guard started == generation else { throw ConnectionError.unavailable }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.unavailable }
            let result = try JSONDecoder().decode(BootstrapResult.self, from: data)
            connected = true
            return result
        } catch {
            diagnostics?((error as NSError).code)
            if started == generation { connected = false }
            throw ConnectionError.unavailable
        }
    }

    func login(deviceID: String) async throws {
        let started = generation
        guard !deviceID.isEmpty else { throw ConnectionError.unavailable }
        let key = try DeviceIdentity.load(account: identityAccount)
        let challenge: Challenge = try await request("/v1/auth/challenge", method: "POST", body: ["device_id": deviceID])
        let input = Data("fuckin-locked-login-v1:\(deviceID):\(challenge.challenge)".utf8)
        let signature = try key.signature(for: input)
        let result: SessionToken = try await request("/v1/auth/session", method: "POST", body: [
            "device_id": deviceID, "challenge": challenge.challenge,
            "signature": signature.base64EncodedString()
        ])
        guard started == generation else { throw ConnectionError.unavailable }
        token = result.token
    }

    func people() async throws -> [Person] {
        guard token != nil else { throw ConnectionError.unavailable }
        let result: PeopleResponse = try await request("/v1/people")
        return result.people
    }

    func requireMessagingCapabilities() async throws {
        let result: [String: [String]] = try await request("/v1/capabilities")
        let required: Set<String> = ["idempotent_envelopes_v1", "delivery_status_v1", "room_inbox_v1", "idempotent_prekeys_v1"]
        guard required.isSubset(of: Set(result["capabilities"] ?? [])) else {
            throw ConnectionError.unavailable
        }
    }

    func requireCallCapabilities() async throws {
        let result: [String: [String]] = try await request("/v1/capabilities")
        guard result["capabilities"]?.contains("encrypted_calls_v1") == true else {
            throw ConnectionError.unavailable
        }
    }

    func registerNotifications(_ token: String) async throws {
        let capabilities: [String: [String]] = try await request("/v1/capabilities")
        guard capabilities["capabilities"]?.contains("generic_push_v1") == true else {
            throw ConnectionError.unavailable
        }
        let _: [String: String] = try await request("/v1/notifications/register", method: "POST", body: ["token": token])
    }

    func accountProfile() async throws -> AccountProfile {
        try await request("/v1/me")
    }

    func inboxActivity() async throws -> Set<String> {
        let result: [String: [String]] = try await request("/v1/inbox/activity")
        return Set(result["rooms"] ?? [])
    }

    func updateProfile(name: String, username: String) async throws -> AccountProfile {
        try await request("/v1/me", method: "POST", body: ["name": name, "username": username])
    }

    func requestDevice(publicKey: String) async throws -> String {
        guard let key = Data(base64Encoded: publicKey), key.count == 32 else {
            throw ConnectionError.invalidResponse
        }
        let result: [String: String] = try await request("/v1/devices/pending", method: "POST",
                                                       body: ["public_key": publicKey])
        guard let id = result["device_id"] else { throw ConnectionError.invalidResponse }
        return try routeID(id)
    }

    func approveDevice(_ id: String) async throws {
        let _: [String: String] = try await request("/v1/devices/\(try routeID(id))/approve",
                                                    method: "POST", body: [:])
    }

    func pairingPublicKey() throws -> String {
        try DeviceIdentity.getOrCreate(account: identityAccount).publicKey.rawRepresentation.base64EncodedString()
    }

    func pendingAdmissions() async throws -> [PendingAdmission] {
        guard token != nil else { throw ConnectionError.unavailable }
        let result: AdmissionsResponse = try await request("/v1/admissions")
        return result.pending
    }

    func approveAdmission(_ id: String) async throws {
        guard token != nil else { throw ConnectionError.unavailable }
        let _: [String: String] = try await request("/v1/admissions/\(id)/approve", method: "POST", body: [:])
    }

    func devices() async throws -> [DeviceInfo] {
        guard token != nil else { throw ConnectionError.unavailable }
        let result: DevicesResponse = try await request("/v1/devices")
        return result.devices
    }

    func invite() async throws -> String {
        guard token != nil else { throw ConnectionError.unavailable }
        let result: Invitation = try await request("/v1/invitations", method: "POST", body: [:])
        return result.code
    }

    func revoke(_ id: String) async throws {
        guard token != nil else { throw ConnectionError.unavailable }
        let _: [String: String] = try await request("/v1/devices/\(id)/revoke", method: "POST", body: [:])
    }

    private func routeID(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 128,
              value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                                      ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else {
            throw ConnectionError.invalidResponse
        }
        return value
    }

    func createOneToOneRoom(with userID: String) async throws -> String {
        guard token != nil else { throw ConnectionError.unavailable }
        let user = try routeID(userID)
        let result: RoomCreated = try await request("/v1/rooms", method: "POST",
                                                     body: ["user_ids": [user]])
        return try routeID(result.room_id)
    }

    func rooms() async throws -> [RoomInfo] {
        guard token != nil else { throw ConnectionError.unavailable }
        let result: RoomsResponse = try await request("/v1/rooms")
        return result.rooms.compactMap { room in
            guard (try? routeID(room.id)) != nil else { return nil }
            return room
        }
    }

    func roomDevices(_ roomID: String) async throws -> [RoomDevice] {
        guard token != nil else { throw ConnectionError.unavailable }
        let room = try routeID(roomID)
        let result: RoomDevices = try await request("/v1/rooms/\(room)/devices")
        return result.devices
    }

    func memberDevices(_ userID: String) async throws -> [RoomDevice] {
        let result: RoomDevices = try await request("/v1/people/\(try routeID(userID))/devices")
        return result.devices
    }

    func createGroup(peerDevices: [String]) async throws -> String {
        let peers = try peerDevices.map { try routeID($0) }
        let result: RoomCreated = try await request("/v1/groups", method: "POST", body: ["peer_devices": peers])
        return try routeID(result.room_id)
    }

    func groupInfo(_ id: String) async throws -> GroupInfo {
        try await request("/v1/groups/\(try routeID(id))")
    }

    func groupLink(_ id: String, peerDevice: String) async throws -> String {
        let result: RoomCreated = try await request("/v1/groups/\(try routeID(id))/links/\(try routeID(peerDevice))",
                                                    method: "POST", body: [:])
        return try routeID(result.room_id)
    }

    func removeGroupMember(_ id: String, userID: String) async throws {
        let _: [String: String] = try await request("/v1/groups/\(try routeID(id))/members/\(try routeID(userID))/remove",
                                                    method: "POST", body: [:])
    }

    func callTURN() async throws -> CallTURN {
        let turn: CallTURN = try await request("/v1/calls/turn")
        // Media uses one separately pinned operator-owned host. An HTTP CDN
        // in front of the HTTPS gateway cannot carry TURN on port 5349.
        guard let expectedHost = Bundle.main.object(forInfoDictionaryKey: "FLTURNHost") as? String else {
            throw ConnectionError.unavailable
        }
        try turn.validateRoute(expectedHost: expectedHost)
        return turn
    }

    func publishPrekeys(_ bundle: SignalPublicBundle, roomID: String) async throws {
        guard token != nil else { throw ConnectionError.unavailable }
        let room = try routeID(roomID)
        let _: [String: String] = try await request("/v1/rooms/\(room)/prekeys",
                                                    method: "POST", body: bundle.requestBody)
    }

    func takePrekeys(roomID: String, deviceID: String, requestID: UUID? = nil) async throws -> RelayPrekeyBundle {
        guard token != nil else { throw ConnectionError.unavailable }
        let room = try routeID(roomID)
        let device = try routeID(deviceID)
        let suffix = requestID.map { "/\($0.uuidString)" } ?? ""
        return try await request("/v1/rooms/\(room)/prekeys/\(device)\(suffix)")
    }

    func sendEnvelope(roomID: String, recipientDevice: String, kind: String,
                      ciphertext: Data, messageID: String? = nil) async throws -> String {
        guard token != nil else { throw ConnectionError.unavailable }
        let room = try routeID(roomID)
        let recipient = try routeID(recipientDevice)
        guard ["message", "attachment", "key_update"].contains(kind) else {
            throw ConnectionError.invalidResponse
        }
        var body: [String: Any] = [
            "room_id": room, "recipient_device": recipient, "kind": kind,
            "ciphertext": ciphertext.base64EncodedString()
        ]
        if let messageID { body["message_id"] = try routeID(messageID) }
        let result: [String: String] = try await request("/v1/envelopes", method: "POST", body: body)
        guard let id = result["id"] else { throw ConnectionError.invalidResponse }
        return try routeID(id)
    }

    func pendingEnvelopes(roomID: String? = nil) async throws -> [RelayEnvelope] {
        guard token != nil else { throw ConnectionError.unavailable }
        let path = try roomID.map { "/v1/rooms/\(try routeID($0))/envelopes/pending" } ?? "/v1/envelopes"
        let result: RelayEnvelopes = try await request(path)
        return result.envelopes
    }

    func envelopeStatus(_ id: String) async throws -> String {
        let result: [String: String] = try await request("/v1/envelopes/\(try routeID(id))/status")
        guard let state = result["state"], ["accepted", "delivered"].contains(state) else {
            throw ConnectionError.invalidResponse
        }
        return state
    }

    func acknowledgeEnvelope(_ id: String) async throws {
        guard token != nil else { throw ConnectionError.unavailable }
        let _: [String: String] = try await request("/v1/envelopes/\(try routeID(id))/ack",
                                                    method: "POST", body: [:])
    }

    func disconnect() {
        generation &+= 1
        session.invalidateAndCancel()
        session = makeGatewaySession()
        token = nil
        connected = false
    }
}

enum DeviceIdentityError: Error {
    case keychain(OSStatus)
    case corrupt
}

enum DeviceIdentity {
    static let defaultAccount = "device-signing-key"

    static func getOrCreate(account: String = defaultAccount) throws -> Curve25519.Signing.PrivateKey {
        do { return try load(account: account) }
        catch DeviceIdentityError.keychain(errSecItemNotFound) {}
        // A locked/unavailable Keychain is not permission to replace an identity.
        let created = Curve25519.Signing.PrivateKey()
        try save(created, account: account)
        return created
    }

    static func save(_ key: Curve25519.Signing.PrivateKey,
                     account: String = defaultAccount) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.fuckinlocked",
            kSecAttrAccount as String: account]
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceIdentityError.keychain(status) }
    }

    static func load(account: String = defaultAccount) throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.fuckinlocked",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw DeviceIdentityError.keychain(status) }
        guard let data = item as? Data else { throw DeviceIdentityError.corrupt }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
}
