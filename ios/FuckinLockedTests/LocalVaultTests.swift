import XCTest
@testable import FuckinLocked

@MainActor final class LocalVaultTests: XCTestCase {
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
}
