import XCTest

final class LockLifecycleTests: XCTestCase {
    @MainActor private func openLockedChat(_ friend: XCUIElement, in app: XCUIApplication) {
        let gate = app.secureTextFields["Chat password"]
        // A delayed system save sheet can consume the first navigation tap.
        // Retry the real row action only while still in the inbox; never
        // authenticate or alter vault state through a test hook.
        for _ in 0..<3 {
            declinePasswordStorageIfPresented(app)
            if gate.exists { return }
            if friend.isHittable { friend.tap() }
            declinePasswordStorageIfPresented(app)
            if gate.waitForExistence(timeout: 2) { return }
        }
    }

    @MainActor private func declinePasswordStorageIfPresented(_ app: XCUIApplication) {
        // On iOS 26 this remote system UI is exposed as an embedded Sheet,
        // so XCTest's interruption monitor does not necessarily run for it.
        let sheet = app.sheets["Save Password?"]
        if sheet.waitForExistence(timeout: 2) {
            XCTAssertTrue(sheet.buttons["Not Now"].isHittable)
            sheet.buttons["Not Now"].tap()
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: sheet)
            waitForExpectations(timeout: 5)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    @MainActor
    func testBackgroundAndRelaunchRequireAppAndChatPasswords() throws {
        // iOS may infer a password-saving prompt even without content-type
        // hints. Dismiss only this known system prompt, never permissions or
        // authentication dialogs, and still type both passwords in full.
        addUIInterruptionMonitor(withDescription: "Decline system password storage") { alert in
            guard alert.staticTexts["Save Password?"].exists,
                  alert.buttons["Not Now"].exists else { return false }
            alert.buttons["Not Now"].tap()
            return true
        }
        let app = XCUIApplication()
        app.launch()
        let appPassword = "uitest app password"
        let chatPassword = "uitest chat password"
        let create = app.buttons["Create password"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "First-launch password setup must appear")
        let firstPassword = app.secureTextFields["App password · 12 characters minimum"]
        firstPassword.tap(); firstPassword.typeText(appPassword)
        let repeatPassword = app.secureTextFields["Repeat password"]
        repeatPassword.tap(); repeatPassword.typeText(appPassword)
        create.tap()
        declinePasswordStorageIfPresented(app)
        let compose = app.buttons["Compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "App password creation must open Chats")
        compose.tap()
        let localDraft = app.buttons["Create a local draft instead"]
        XCTAssertTrue(localDraft.waitForExistence(timeout: 5))
        localDraft.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Compose must open the local draft form")
        name.tap(); name.typeText("Lifecycle test friend")
        let separate = app.secureTextFields["Separate chat password"]
        separate.tap(); separate.typeText(chatPassword)
        app.buttons["Create locked draft"].tap()
        declinePasswordStorageIfPresented(app)
        let friend = app.staticTexts["Lifecycle test friend"].firstMatch
        XCTAssertTrue(friend.waitForExistence(timeout: 5), "Created local draft must appear in Chats")
        openLockedChat(friend, in: app)
        let chatField = app.secureTextFields["Chat password"]
        XCTAssertTrue(chatField.waitForExistence(timeout: 5), "Opening a chat must require its password")
        chatField.tap(); chatField.typeText(chatPassword)
        app.buttons["Unlock chat"].tap()
        declinePasswordStorageIfPresented(app)
        // The unlock gate's dismiss action is named Close; seeing the
        // conversation-only Lock chat action proves the password transition
        // completed without exposing the chat before authentication.
        XCTAssertTrue(app.buttons["Lock chat"].waitForExistence(timeout: 15),
                      "Unlock must show the conversation after its password")
        let composer = app.otherElements["message-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertLessThan(composer.frame.height, 160,
                          "The composer must remain a compact row, not consume the conversation")

        XCUIDevice.shared.press(.home)
        app.activate()
        declinePasswordStorageIfPresented(app)
        let unlock = app.secureTextFields["App password"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), "Returning from Home must require app password")
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
        unlock.tap(); unlock.typeText(appPassword)
        app.buttons["Unlock"].tap()
        declinePasswordStorageIfPresented(app)
        // App unlock intentionally performs the vault KDF before the inbox can
        // render; allow the security work plus the SwiftUI transition to
        // complete instead of treating it as a lock bypass/failure.
        XCTAssertTrue(friend.waitForExistence(timeout: 15), "App unlock after background must reopen Chats")
        openLockedChat(friend, in: app)
        XCTAssertTrue(chatField.waitForExistence(timeout: 5), "Chat must be relocked after background")
        XCTAssertFalse(app.buttons["Lock chat"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.secureTextFields["App password"].waitForExistence(timeout: 10), "Relaunch must require app password")
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
    }
}
