import XCTest
import LibSignalClient
@testable import FuckinLocked

@MainActor final class LocalVaultTests: XCTestCase {
    func testRelockInvalidatesAsyncGenerationAndEncryptedOutboxSurvivesRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("correct app password")
        try vault.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        let id = try XCTUnwrap(vault.chats.first?.id)
        try vault.unlockChat(id, password: "separate chat password")
        let generation = vault.chatGeneration
        let message = StoredMessage(id: UUID(), body: "private queued content", sentAt: Date(),
                                    isOutgoing: true, delivery: .sending, envelopeID: nil,
                                    ciphertext: Data(repeating: 42, count: 96))
        try vault.commitChat(state: .new(), message: message, for: id)
        vault.lockChat()
        XCTAssertNotEqual(vault.chatGeneration, generation)
        XCTAssertThrowsError(try vault.signalState(for: id))
        let restarted = LocalVault(directory: root)
        try restarted.unlock("correct app password")
        XCTAssertTrue(restarted.messageRecords.isEmpty)
        try restarted.unlockChat(id, password: "separate chat password")
        XCTAssertEqual(restarted.messageRecords.first, message)
        let saved = try Data(contentsOf: root.appendingPathComponent("vault.bin"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(message.body))
    }

    func testStructuredContentRejectsUnboundedImagesAndInvalidReactions() throws {
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "", image: Data(repeating: 0, count: 256_001)).validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "", reactionTarget: UUID(), reaction: "arbitrary").validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "").validate())
        XCTAssertNoThrow(try MessageContent(id: UUID(), text: "hello").validate())
        XCTAssertNoThrow(try MessageContent(id: UUID(), text: "", reactionTarget: UUID(), reaction: "💚").validate())
    }

    func testVoiceCallSignalsAreBoundedAndCannotCarryChatContent() throws {
        let signal = CallSignal(callID: UUID(), kind: "offer", body: Data(repeating: 7, count: 128))
        XCTAssertNoThrow(try signal.validate())
        XCTAssertNoThrow(try MessageContent(id: UUID(), text: "", callSignal: signal).validate())
        XCTAssertThrowsError(try CallSignal(callID: UUID(), kind: "stun", body: Data()).validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "not empty", callSignal: signal).validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "", image: Data([1]), callSignal: signal).validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "", groupID: "group", callSignal: signal).validate())
        XCTAssertThrowsError(try CallSignal(callID: UUID(), kind: "ice",
                                            body: Data(repeating: 0, count: CallSignal.maxBytes + 1)).validate())
    }
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testAppAndChatRelockAfterRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalVault(directory: root)
        try first.createAppPassword("correct app password")
        try first.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        let id = try XCTUnwrap(first.chats.first?.id)
        try first.unlockChat(id, password: "separate chat password")
        XCTAssertEqual(first.unlockedChatID, id)
        first.lockApp()
        XCTAssertFalse(first.isUnlocked)
        XCTAssertNil(first.unlockedChatID)
        XCTAssertTrue(first.messages.isEmpty)
        let restarted = LocalVault(directory: root)
        XCTAssertFalse(restarted.isUnlocked)
        try restarted.unlock("correct app password")
        XCTAssertNil(restarted.unlockedChatID)
        try restarted.unlockChat(id, password: "separate chat password")
    }

    func testFailureDelayPersistsAcrossRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalVault(directory: root)
        try first.createAppPassword("correct app password")
        first.lockApp()
        XCTAssertThrowsError(try first.unlock("wrong password"))
        let restarted = LocalVault(directory: root)
        XCTAssertThrowsError(try restarted.unlock("correct app password")) { error in
            guard case VaultError.delayed = error else { XCTFail("Expected persistent delay"); return }
        }
    }

    func testChatFailureDelayPersistsAcrossRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalVault(directory: root)
        try first.createAppPassword("correct app password")
        try first.createChat(title: "Friend", isGroup: false, password: "correct chat password")
        let id = try XCTUnwrap(first.chats.first?.id)
        XCTAssertThrowsError(try first.unlockChat(id, password: "wrong chat password"))
        first.lockApp()

        let restarted = LocalVault(directory: root)
        try restarted.unlock("correct app password")
        XCTAssertThrowsError(try restarted.unlockChat(id, password: "correct chat password")) { error in
            guard case VaultError.delayed = error else { XCTFail("Expected persistent chat delay"); return }
        }
    }

    func testPasswordChangeRewrapsKeyAndPreservesEncryptedIndex() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("old app password")
        try vault.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        try vault.changeAppPassword(old: "old app password", new: "new app password")
        vault.lockApp()
        let restarted = LocalVault(directory: root)
        try restarted.unlock("new app password")
        XCTAssertEqual(restarted.chats.first?.title, "Friend")
        try restarted.unlockChat(try XCTUnwrap(restarted.chats.first?.id), password: "separate chat password")
    }

    func testPasswordWrapperStaysCommittedAfterSubsequentIndexWrites() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("old app password")
        try vault.changeAppPassword(old: "old app password", new: "new app password")
        try vault.createChat(title: "After replacement", isGroup: false, password: "separate chat password")
        vault.lockApp()
        let reopened = LocalVault(directory: root)
        try reopened.unlock("new app password")
        XCTAssertEqual(reopened.chats.first?.title, "After replacement")
    }

    func testInterruptedPasswordChangeDoesNotResurrectOldWrapper() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var failDelayWrites = false
        let vault = LocalVault(directory: root, beforeWrite: { url in
            if failDelayWrites && url.lastPathComponent == "delay.bin" { throw VaultError.corrupt }
        })
        try vault.createAppPassword("old app password")
        failDelayWrites = true
        XCTAssertThrowsError(try vault.changeAppPassword(old: "old app password", new: "new app password"))
        failDelayWrites = false
        try vault.createChat(title: "After interruption", isGroup: false, password: "separate chat password")
        vault.lockApp()
        let reopened = LocalVault(directory: root)
        try reopened.unlock("new app password")
        XCTAssertEqual(reopened.chats.first?.title, "After interruption")
    }

    func testFailedAtomicVaultWritePreservesPreviousPassword() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var failVaultWrites = false
        let vault = LocalVault(directory: root, beforeWrite: { url in
            if failVaultWrites && url.lastPathComponent == "vault.bin" { throw VaultError.corrupt }
        })
        try vault.createAppPassword("old app password")
        failVaultWrites = true
        XCTAssertThrowsError(try vault.changeAppPassword(old: "old app password", new: "new app password"))
        vault.lockApp()
        let reopened = LocalVault(directory: root)
        try reopened.unlock("old app password")
    }

    func testStarterStickersAreBoundedImagesAndLibraryIsChatEncrypted() throws {
        for sticker in StarterStickers.items { XCTAssertNoThrow(try PrivateImage.validate(sticker.imageData())) }
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("correct app password")
        try vault.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        let id = try XCTUnwrap(vault.chats.first?.id)
        try vault.unlockChat(id, password: "separate chat password")
        var library = ComposerLibrary()
        library.favoriteStickers.insert("moon")
        try vault.saveComposerLibrary(library, for: id)
        vault.lockChat()
        XCTAssertThrowsError(try vault.composerLibrary(for: id))
        try vault.unlockChat(id, password: "separate chat password")
        XCTAssertEqual(try vault.composerLibrary(for: id).favoriteStickers, ["moon"])
    }

    func testVaultFileDoesNotContainNamesOrPasswords() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("app password one two")
        try vault.createChat(title: "Private contact name", isGroup: false,
                             password: "chat password one two")
        let bytes = try Data(contentsOf: root.appendingPathComponent("vault.bin"))
        let representation = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(representation.contains("Private contact name"))
        XCTAssertFalse(representation.contains("app password one two"))
        XCTAssertFalse(representation.contains("chat password one two"))
    }

    func testMissingDelayLedgerFailsClosed() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalVault(directory: root)
        try first.createAppPassword("correct app password")
        first.lockApp()
        try FileManager.default.removeItem(at: root.appendingPathComponent("delay.bin"))
        let restarted = LocalVault(directory: root)
        XCTAssertThrowsError(try restarted.unlock("correct app password"))
        XCTAssertFalse(restarted.isUnlocked)
    }

    func testChatPasswordChangeRewrapsContentKey() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("correct app password")
        try vault.createChat(title: "Friend", isGroup: false, password: "old chat password")
        let id = try XCTUnwrap(vault.chats.first?.id)
        let previousCiphertext = try XCTUnwrap(vault.chats.first?.ciphertext)
        try vault.changeChatPassword(id, old: "old chat password", new: "new chat password")
        XCTAssertEqual(vault.chats.first?.ciphertext, previousCiphertext)
        vault.lockApp()
        let restarted = LocalVault(directory: root)
        try restarted.unlock("correct app password")
        try restarted.unlockChat(id, password: "new chat password")
        XCTAssertEqual(restarted.unlockedChatID, id)
    }

    func testProtocolIdentityNeedsChatPasswordAfterRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalVault(directory: root)
        try first.createAppPassword("correct app password")
        try first.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        let id = try XCTUnwrap(first.chats.first?.id)
        try first.unlockChat(id, password: "separate chat password")
        let state = SignalState.new()
        try first.saveSignalState(state, for: id)
        first.lockApp()

        let restarted = LocalVault(directory: root)
        try restarted.unlock("correct app password")
        XCTAssertThrowsError(try restarted.signalState(for: id))
        try restarted.unlockChat(id, password: "separate chat password")
        XCTAssertEqual(try restarted.signalState(for: id)?.identityKeyPair, state.identityKeyPair)
    }

    func testProtocolIdentityChangeRequiresExplicitReview() throws {
        let store = VaultSignalStore(state: .new())
        let address = try ProtocolAddress(name: "room:peer", deviceId: 1)
        let first = IdentityKeyPair.generate().identityKey
        let changed = IdentityKeyPair.generate().identityKey
        XCTAssertFalse(try store.isTrustedIdentity(first, for: address, direction: .sending,
                                                    context: NullContext()))
        try store.approveIdentity(first, for: address)
        XCTAssertTrue(try store.isTrustedIdentity(first, for: address, direction: .sending,
                                                  context: NullContext()))
        XCTAssertThrowsError(try store.approveIdentity(changed, for: address))
        XCTAssertFalse(try store.isTrustedIdentity(changed, for: address, direction: .sending,
                                                    context: NullContext()))
    }

    func testGeneratedPublicBundleIsSignedAndPrivateRecordsStayInStore() throws {
        let store = VaultSignalStore(state: .new())
        let bundle = try store.generatePublicBundle()
        let identity = try IdentityKey(bytes: bundle.identityKey)
        XCTAssertTrue(try identity.publicKey.verifySignature(message: bundle.signedPreKey,
                                                              signature: bundle.signedPreKeySignature))
        XCTAssertTrue(try identity.publicKey.verifySignature(message: bundle.kyberPreKey,
                                                              signature: bundle.kyberPreKeySignature))
        XCTAssertNotNil(store.state.preKeys[bundle.oneTimePreKeyID])
        XCTAssertNotNil(store.state.signedPreKeys[bundle.signedPreKeyID])
        XCTAssertNotNil(store.state.kyberPreKeys[bundle.kyberPreKeyID])
        let publicDescription = String(describing: bundle.requestBody)
        XCTAssertFalse(publicDescription.contains(store.state.identityKeyPair.base64EncodedString()))
    }
}
