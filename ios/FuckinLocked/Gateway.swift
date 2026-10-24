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
    return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
}

struct Admission: Decodable {
    let admission_id: String
    let user_id: String
    let device_id: String
    let state: String
}
struct BootstrapResult: Decodable { let user_id: String; let device_id: String }

struct Challenge: Decodable { let challenge: String }
struct SessionToken: Decodable { let token: String }
struct Invitation: Decodable { let code: String }
struct Person: Decodable, Identifiable { let id: String; let name: String; let username: String }
struct PeopleResponse: Decodable { let people: [Person] }
struct PendingAdmission: Decodable, Identifiable { let id: String; let name: String; let username: String; let created_at: Int }
struct AdmissionsResponse: Decodable { let pending: [PendingAdmission] }
struct DeviceInfo: Decodable, Identifiable { let id: String; let state: String; let created_at: Int }
struct DevicesResponse: Decodable { let devices: [DeviceInfo] }

@MainActor final class Gateway: ObservableObject {
    @Published private(set) var connected = false
    private var token: String?
    private var generation = 0
    private var session = makeGatewaySession()

    private var base: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "FLGatewayURL") as? String,
              let url = URL(string: value), url.scheme == "https",
              let host = url.host, host != "REPLACE_WITH_GATEWAY_HOST" else { return nil }
        return url
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let started = generation
        guard let base, let url = URL(string: path, relativeTo: base) else { throw ConnectionError.unavailable }
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
            guard started == generation else { throw ConnectionError.unavailable }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ConnectionError.unavailable
            }
            connected = true
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if started == generation { connected = false }
            throw ConnectionError.unavailable
        }
    }

    func enroll(code: String, name: String, username: String) async throws -> Admission {
        let key = try DeviceIdentity.getOrCreate()
        let result: Admission = try await request("/v1/admissions", method: "POST", body: [
            "code": code, "name": name, "username": username,
            "public_key": key.publicKey.rawRepresentation.base64EncodedString()
        ])
        return result
    }

    func bootstrap(token: String, name: String, username: String) async throws -> BootstrapResult {
        let started = generation
        let key = try DeviceIdentity.getOrCreate()
        guard let base, let url = URL(string: "/v1/bootstrap", relativeTo: base) else {
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
            guard started == generation else { throw ConnectionError.unavailable }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.unavailable }
            let result = try JSONDecoder().decode(BootstrapResult.self, from: data)
            connected = true
            return result
        } catch {
            if started == generation { connected = false }
            throw ConnectionError.unavailable
        }
    }

    func login(deviceID: String) async throws {
        let started = generation
        guard !deviceID.isEmpty else { throw ConnectionError.unavailable }
        let key = try DeviceIdentity.load()
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

    func disconnect() {
        generation &+= 1
        session.invalidateAndCancel()
        session = makeGatewaySession()
        token = nil
        connected = false
    }
}

enum DeviceIdentity {
    private static let account = "device-signing-key"

    static func getOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try? load() { return existing }
        let created = Curve25519.Signing.PrivateKey()
        try save(created)
        return created
    }

    static func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.fuckinlocked",
            kSecAttrAccount as String: account]
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.unavailable }
    }

    static func load() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.fuckinlocked",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { throw ConnectionError.unavailable }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
}
