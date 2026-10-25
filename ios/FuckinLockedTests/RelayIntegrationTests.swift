import Foundation
import XCTest
import UIKit
@testable import FuckinLocked

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // This delegate is only injected into the local self-signed CI fixture.
        // Production Gateway instances use URLSession's normal system trust path.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class OfflineTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@MainActor final class RelayIntegrationTests: XCTestCase {
    func testTwoIsolatedClientsExchangeMessagesThroughRelay() async throws {
        guard ProcessInfo.processInfo.environment["FL_RUN_RELAY_INTEGRATION"] == "1" else {
            throw XCTSkip("The local HTTPS relay fixture is enabled by the macOS workflow")
        }
        var stage = "trusted HTTPS health"
        do {
        let delegate = LoopbackTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let baseURL = try XCTUnwrap(URL(string: "https://127.0.0.1:8787/fuckin-locked/"))
        let (_, healthResponse) = try await session.data(from: baseURL.appendingPathComponent("health"))
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        let suffix = UUID().uuidString.lowercased()
        let aliceGateway = Gateway(baseURL: baseURL, session: session,
                                   identityAccount: "relay-integration-alice-\(suffix)",
                                   diagnostics: { print("Alice fixture HTTP/error code: \($0)") })
        let bobGateway = Gateway(baseURL: baseURL, session: session,
                                 identityAccount: "relay-integration-bob-\(suffix)",
                                 diagnostics: { print("Bob fixture HTTP/error code: \($0)") })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuckin-locked-relay-integration-\(suffix)")
        defer { try? FileManager.default.removeItem(at: root) }

        let aliceVault = LocalVault(directory: root.appendingPathComponent("alice"))
        let bobVault = LocalVault(directory: root.appendingPathComponent("bob"))
        try aliceVault.createAppPassword("alice app password")
        try bobVault.createAppPassword("bob app password")

        stage = "first device bootstrap"
        let aliceBootstrap = try await aliceGateway.bootstrap(token: "ci-bootstrap-token",
                                                               name: "Alice", username: "alice")
        try aliceVault.setProfile(name: "Alice", username: "alice",
                                  userID: aliceBootstrap.user_id, deviceID: aliceBootstrap.device_id)
        try await aliceGateway.login(deviceID: aliceBootstrap.device_id)
        stage = "invitation and approval"
        let invitation = try await aliceGateway.invite()
        let admission = try await bobGateway.enroll(code: invitation, name: "Bob", username: "bob")
        try await aliceGateway.approveAdmission(admission.admission_id)
        let bobDeviceID = admission.device_id
        try bobVault.setProfile(name: "Bob", username: "bob",
                                userID: admission.user_id, deviceID: bobDeviceID)
        try await bobGateway.login(deviceID: bobDeviceID)

        let people = try await aliceGateway.people()
        stage = "room creation"
        let bobPerson = try XCTUnwrap(people.first(where: { $0.id == admission.user_id }))
        let roomID = try await aliceGateway.createOneToOneRoom(with: bobPerson.id)
        let aliceDevices = try await aliceGateway.roomDevices(roomID)
        let bobDevices = try await bobGateway.roomDevices(roomID)
        let alicePeerDevice = try XCTUnwrap(aliceDevices.first(where: { $0.user_id == bobPerson.id }))
        let bobPeerDevice = try XCTUnwrap(bobDevices.first(where: { $0.user_id == aliceBootstrap.user_id }))

        try aliceVault.createChat(title: "Bob", isGroup: false, password: "alice chat password",
                                  roomID: roomID, remoteUserID: bobPerson.id,
                                  remoteDeviceID: alicePeerDevice.id)
        try bobVault.createChat(title: "Alice", isGroup: false, password: "bob chat password",
                                roomID: roomID, remoteUserID: aliceBootstrap.user_id,
                                remoteDeviceID: bobPeerDevice.id)
        let aliceChatID = try XCTUnwrap(aliceVault.chats.first?.id)
        let bobChatID = try XCTUnwrap(bobVault.chats.first?.id)
        try aliceVault.unlockChat(aliceChatID, password: "alice chat password")
        try bobVault.unlockChat(bobChatID, password: "bob chat password")

        var aliceState = try aliceVault.signalState(for: aliceChatID) ?? SignalState.new()
        let aliceStore = VaultSignalStore(state: aliceState)
        let aliceBundle = try aliceStore.generatePublicBundle()
        aliceState = aliceStore.state
        try aliceVault.saveSignalState(aliceState, for: aliceChatID)
        try await aliceGateway.publishPrekeys(aliceBundle, roomID: roomID)

        var bobState = try bobVault.signalState(for: bobChatID) ?? SignalState.new()
        let bobStore = VaultSignalStore(state: bobState)
        let bobBundle = try bobStore.generatePublicBundle()
        bobState = bobStore.state
        try bobVault.saveSignalState(bobState, for: bobChatID)
        try await bobGateway.publishPrekeys(bobBundle, roomID: roomID)

        let aliceMessaging = MessagingService(vault: aliceVault, gateway: aliceGateway)
        let bobMessaging = MessagingService(vault: bobVault, gateway: bobGateway)
        stage = "identity verification and prekeys"
        let alicePeerFingerprint = try await aliceMessaging.preparePeerVerification(for: aliceChatID)
        let bobPeerFingerprint = try await bobMessaging.preparePeerVerification(for: bobChatID)
        XCTAssertFalse(alicePeerFingerprint.isEmpty)
        XCTAssertFalse(bobPeerFingerprint.isEmpty)
        try aliceMessaging.verifyPeer(for: aliceChatID)
        try bobMessaging.verifyPeer(for: bobChatID)

        stage = "Alice sends and Bob receives"
        try await aliceMessaging.send("hello from alice", in: aliceChatID)
        XCTAssertEqual(aliceVault.messageRecords.last?.delivery, .accepted)
        try await bobMessaging.receive(in: bobChatID)
        XCTAssertEqual(bobVault.messageRecords.last?.body, "hello from alice")
        XCTAssertEqual(bobVault.messageRecords.last?.isOutgoing, false)

        stage = "Bob replies"
        try await bobMessaging.send("hello from bob", in: bobChatID)
        try await aliceMessaging.receive(in: aliceChatID)
        XCTAssertEqual(aliceVault.messageRecords.last?.body, "hello from bob")
        XCTAssertEqual(aliceVault.messageRecords.last?.isOutgoing, false)
        try await aliceMessaging.receive(in: aliceChatID)
        XCTAssertEqual(aliceVault.messageRecords.first?.delivery, .delivered)
        XCTAssertEqual(aliceVault.messageRecords.filter { !$0.isOutgoing }.count, 1)
        // Reopening from disk requires both passwords and preserves the ratchet.
        stage = "restart and ratchet persistence"
        bobVault.lockApp()
        try bobVault.unlock("bob app password")
        try bobVault.unlockChat(bobChatID, password: "bob chat password")
        try await bobMessaging.send("after restart", in: bobChatID)
        try await aliceMessaging.receive(in: aliceChatID)
        XCTAssertEqual(aliceVault.messageRecords.last?.body, "after restart")
        stage = "encrypted reactions"
        let target = try XCTUnwrap(bobVault.messageRecords.first(where: { !$0.isOutgoing })?.id)
        try await bobMessaging.react("💚", to: target, in: bobChatID)
        try await aliceMessaging.receive(in: aliceChatID)
        XCTAssertEqual(aliceVault.messageRecords.first(where: { $0.id == target })?.reactions?["peer"], "💚")
        stage = "encrypted images"
        let raster = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let jpeg = try PrivateImage.importImage(XCTUnwrap(raster.pngData()))
        try await aliceMessaging.sendImage(jpeg, in: aliceChatID)
        try await bobMessaging.receive(in: bobChatID)
        XCTAssertEqual(bobVault.messageRecords.last?.image, jpeg)
        bobVault.lockApp()
        let saved = try Data(contentsOf: root.appendingPathComponent("bob/vault.bin"))
        XCTAssertNil(saved.range(of: jpeg))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("hello from alice"))
        stage = "offline outbox recovery"
        let offlineConfiguration = URLSessionConfiguration.ephemeral
        offlineConfiguration.protocolClasses = [OfflineTransport.self]
        let offlineGateway = Gateway(baseURL: baseURL,
            session: URLSession(configuration: offlineConfiguration),
            identityAccount: "relay-integration-alice-\(suffix)")
        let offlineMessaging = MessagingService(vault: aliceVault, gateway: offlineGateway)
        do {
            try await offlineMessaging.send("queued while offline", in: aliceChatID)
            XCTFail("Offline send should remain queued")
        } catch MessagingError.queued {}
        XCTAssertEqual(aliceVault.messageRecords.last?.delivery, .sending)
        let abandonedCall = CallSignal(callID: UUID(), kind: "offer", body: Data([1]))
        do {
            try await offlineMessaging.sendCallSignal(abandonedCall, in: aliceChatID)
            XCTFail("Offline call signaling must fail")
        } catch { }
        XCTAssertFalse(aliceVault.messageRecords.contains { $0.callSignal?.callID == abandonedCall.callID },
                       "An abandoned call must never enter the durable retry outbox")
        aliceVault.lockApp()
        try aliceVault.unlock("alice app password")
        try aliceVault.unlockChat(aliceChatID, password: "alice chat password")
        try await aliceMessaging.receive(in: aliceChatID)
        try bobVault.unlock("bob app password")
        try bobVault.unlockChat(bobChatID, password: "bob chat password")
        try await bobMessaging.receive(in: bobChatID)
        try await aliceMessaging.receive(in: aliceChatID)
        XCTAssertEqual(bobVault.messageRecords.filter { $0.body == "queued while offline" }.count, 1)
        XCTAssertFalse(bobVault.messageRecords.contains { $0.callSignal?.callID == abandonedCall.callID },
                       "Reconnection must not replay an abandoned call")

        stage = "additional device approval and revocation"
        let linkedGateway = Gateway(baseURL: baseURL, session: session,
            identityAccount: "relay-integration-linked-bob-\(suffix)")
        let pendingDevice = try await bobGateway.requestDevice(publicKey: linkedGateway.pairingPublicKey())
        do {
            try await linkedGateway.login(deviceID: pendingDevice)
            XCTFail("Pending device must not authenticate")
        } catch ConnectionError.unavailable {}
        try await bobGateway.approveDevice(pendingDevice)
        try await linkedGateway.login(deviceID: pendingDevice)
        let linkedProfile = try await linkedGateway.accountProfile()
        XCTAssertEqual(linkedProfile.user_id, admission.user_id)
        let restoredHistory = try await linkedGateway.pendingEnvelopes(roomID: roomID)
        XCTAssertTrue(restoredHistory.isEmpty)
        try await linkedGateway.revoke(bobDeviceID)
        do {
            _ = try await bobGateway.people()
            XCTFail("Revocation must invalidate an existing authenticated session")
        } catch ConnectionError.unavailable {}
        do {
            try await aliceMessaging.send("after device revocation", in: aliceChatID)
            XCTFail("A bound revoked recipient must not receive a new envelope")
        } catch MessagingError.queued {}
        let silentlyForwarded = try await linkedGateway.pendingEnvelopes(roomID: roomID)
        XCTAssertTrue(silentlyForwarded.isEmpty)
        } catch {
            if case DeviceIdentityError.keychain(let status) = error {
                XCTFail("Keychain OSStatus at \(stage): \(status)")
            }
            XCTFail("Relay integration failed at: \(stage). Error type: \(type(of: error))")
            throw error
        }
    }
}
