import XCTest
@testable import FuckinLocked

@MainActor final class VoiceCallTests: XCTestCase {
    func testUnansweredOutgoingCallStopsMediaButConnectedCallDoesNotExpire() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        await c.startOutgoing()
        XCTAssertTrue(c.isActive)
        c.expireUnansweredCall(at: Date().addingTimeInterval(91))
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(f.session.stopped)
        XCTAssertEqual(c.status, "Call unanswered")
        await c.startOutgoing()
        f.session.state = .connected
        c.expireUnansweredCall(at: Date().addingTimeInterval(91))
        XCTAssertTrue(c.isActive)
    }

    func testIncomingOfferExpiresWithoutCreatingMedia() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let offer = record()
        c.consume([offer])
        c.expireUnansweredCall(at: Date().addingTimeInterval(91))
        XCTAssertFalse(c.hasIncomingOffer)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(f.made, 0)
        c.consume([offer])
        XCTAssertFalse(c.hasIncomingOffer)
    }

    func testTURNRouteIsPinnedTLSOnlyAndHasNoAlternateHost() throws {
        let expected = "turn.freedomhub.at"
        let valid = CallTURN(url: "turns:turn.freedomhub.at:5349?transport=tcp", username: "test", credential: "test")
        XCTAssertNoThrow(try valid.validateRoute(expectedHost: expected))
        XCTAssertThrowsError(try valid.validateRoute(expectedHost: ""))
        for url in ["turn:turn.freedomhub.at:3478?transport=tcp",
                    "turns:turn.freedomhub.at.evil.invalid:5349?transport=tcp",
                    "turns:other.invalid:5349?transport=tcp",
                    "turns:user:password@turn.freedomhub.at:5349?transport=tcp",
                    "turns:turn.freedomhub.at:5349?transport=udp",
                    "turns:turn.freedomhub.at:5349/path?transport=tcp"] {
            XCTAssertThrowsError(try CallTURN(url: url, username: "test", credential: "test")
                .validateRoute(expectedHost: expected))
        }
    }

    @MainActor private final class Session: VoiceCallSession {
        var state: VoiceCallState = .starting
        var received: [CallSignal] = []
        var stopped = false
        var start: (() async throws -> Void)?
        func startOutgoing() async throws { try await start?(); state = .connecting }
        func receive(_ signal: CallSignal) async throws { received.append(signal); state = .connecting }
        func stop(sendHangup: Bool) { stopped = true; state = .ended }
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault: LocalVault
        let id: UUID
        let session = Session()
        var active = true
        var verified = true
        var made = 0
        var fetched = 0
        var sent: [CallSignal] = []
        var turn: (() async throws -> CallTURN)?
        var emit: ((CallSignal) -> Void)?
        let config = CallTURN(url: "turns:example.invalid:5349?transport=tcp", username: "test", credential: "test")

        init() throws {
            vault = LocalVault(directory: root)
            try vault.createAppPassword("correct app password")
            try vault.createChat(title: "Friend", isGroup: false, password: "separate chat password")
            id = try XCTUnwrap(vault.chats.first?.id)
            try vault.unlockChat(id, password: "separate chat password")
        }
        func coordinator() -> VoiceCallCoordinator {
            VoiceCallCoordinator(id: id, vault: vault, dependencies: VoiceCallDependencies(
                isActive: { self.active }, isVerified: { self.verified },
                turn: { self.fetched += 1; return try await self.turn?() ?? self.config },
                makeSession: { _, _, _, send in self.made += 1; self.emit = send; return self.session },
                send: { self.sent.append($0) }))
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func record(_ kind: String = "offer", callID: UUID = UUID(), date: Date = Date()) -> StoredMessage {
        StoredMessage(id: UUID(), body: "", sentAt: date, isOutgoing: false,
                      delivery: .received, envelopeID: nil, ciphertext: nil,
                      callSignal: CallSignal(callID: callID, kind: kind, body: kind == "hangup" ? Data() : Data([1])))
    }

    func testIncomingRequiresExplicitConsentAndDeclineCannotReplay() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let offer = record()
        c.consume([offer])
        XCTAssertTrue(c.hasIncomingOffer)
        XCTAssertEqual(f.fetched, 0)
        XCTAssertEqual(f.made, 0)
        XCTAssertTrue(f.sent.isEmpty)
        c.stop(sendHangup: false)
        c.consume([offer])
        XCTAssertFalse(c.hasIncomingOffer)
        c.consume([record()])
        await c.acceptIncoming()
        XCTAssertEqual(f.made, 1)
        XCTAssertEqual(f.session.received.first?.kind, "offer")
        f.vault.lockChat()
        XCTAssertTrue(f.session.stopped)
        XCTAssertFalse(c.isActive)
    }

    func testUnverifiedInactiveLockedAndStaleOffersNeverCreateMedia() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        f.verified = false
        c.consume([record()]); await c.startOutgoing()
        XCTAssertFalse(c.hasIncomingOffer)
        f.verified = true; f.active = false
        c.consume([record()]); await c.startOutgoing()
        f.active = true
        c.consume([record(date: Date().addingTimeInterval(-301)), record(date: Date().addingTimeInterval(60))])
        XCTAssertFalse(c.hasIncomingOffer)
        c.consume([record()])
        f.verified = false
        await c.acceptIncoming()
        f.vault.lockApp()
        c.consume([record()]); await c.startOutgoing()
        XCTAssertEqual(f.made, 0)
        XCTAssertEqual(f.fetched, 0)
    }

    func testLockDuringTURNFetchPreventsLateEngineCreationAndConcurrentStarts() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let entered = expectation(description: "TURN suspended")
        var resume: CheckedContinuation<CallTURN, Error>?
        f.turn = { try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() } }
        let task = Task { await c.startOutgoing() }
        await fulfillment(of: [entered], timeout: 2)
        await c.startOutgoing()
        XCTAssertEqual(f.fetched, 1)
        f.vault.lockApp()
        resume?.resume(returning: f.config)
        await task.value
        XCTAssertEqual(f.made, 0)
        XCTAssertFalse(c.isActive)
    }

    func testLockDuringMediaSetupStopsSynchronouslyAndDropsLateSignals() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let entered = expectation(description: "media suspended")
        var resume: CheckedContinuation<Void, Error>?
        f.session.start = { try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() } }
        let task = Task { await c.startOutgoing() }
        await fulfillment(of: [entered], timeout: 2)
        f.vault.lockChat()
        XCTAssertTrue(f.session.stopped)
        f.emit?(CallSignal(callID: UUID(), kind: "ice", body: Data([1])))
        resume?.resume()
        await task.value
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testMatchingHangupCancelsPendingOfferAndUnrelatedHangupDoesNot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let callID = UUID()
        c.consume([record(callID: callID), record("hangup")])
        XCTAssertTrue(c.hasIncomingOffer)
        c.consume([record("hangup", callID: callID)])
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(f.made, 0)
    }

    func testMediaSetupFailureClosesSessionAndAllowsRetry() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        f.session.start = { throw VoiceCallError.microphoneDenied }
        await c.startOutgoing()
        XCTAssertTrue(f.session.stopped)
        XCTAssertFalse(c.isActive)
        f.session.start = nil
        await c.startOutgoing()
        XCTAssertEqual(f.made, 2)
        XCTAssertTrue(c.isActive)
    }

    func testIdentityChangeWhileTURNIsSuspendedRejectsSetup() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.coordinator(); defer { c.close() }
        let entered = expectation(description: "TURN suspended")
        var resume: CheckedContinuation<CallTURN, Error>?
        f.turn = { try await withCheckedThrowingContinuation { resume = $0; entered.fulfill() } }
        c.consume([record()])
        let task = Task { await c.acceptIncoming() }
        await fulfillment(of: [entered], timeout: 2)
        await c.acceptIncoming()
        XCTAssertTrue(c.isActive, "A duplicate Accept tap must not cancel the pending setup")
        XCTAssertEqual(f.fetched, 1)
        f.verified = false
        resume?.resume(returning: f.config)
        await task.value
        XCTAssertEqual(f.made, 0)
        XCTAssertFalse(c.isActive)
    }
}
