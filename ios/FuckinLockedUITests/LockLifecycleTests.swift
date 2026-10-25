import XCTest

final class LockLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    @MainActor
    func testBackgroundAndRelaunchRequireAppAndChatPasswords() throws {
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
        let compose = app.buttons["Compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "App password creation must open Chats")
        compose.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Compose must open the local draft form")
        name.tap(); name.typeText("Lifecycle test friend")
        let separate = app.secureTextFields["Separate chat password"]
        separate.tap(); separate.typeText(chatPassword)
        app.buttons["Create locked draft"].tap()
        let friend = app.staticTexts["Lifecycle test friend"].firstMatch
        XCTAssertTrue(friend.waitForExistence(timeout: 5), "Created local draft must appear in Chats")
        friend.tap()
        let chatField = app.secureTextFields["Chat password"]
        XCTAssertTrue(chatField.waitForExistence(timeout: 5), "Opening a chat must require its password")
        chatField.tap(); chatField.typeText(chatPassword)
        app.buttons["Unlock chat"].tap()
        let localDraftStatus = app.descendants(matching: .any)["local-draft-status"]
        XCTAssertTrue(localDraftStatus.waitForExistence(timeout: 15),
                      "Unlock must show an honestly labeled local draft")

        XCUIDevice.shared.press(.home)
        app.activate()
        let unlock = app.secureTextFields["App password"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), "Returning from Home must require app password")
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
        unlock.tap(); unlock.typeText(appPassword)
        app.buttons["Unlock"].tap()
        // App unlock intentionally performs the vault KDF before the inbox can
        // render; allow the security work plus the SwiftUI transition to
        // complete instead of treating it as a lock bypass/failure.
        XCTAssertTrue(friend.waitForExistence(timeout: 15), "App unlock after background must reopen Chats")
        friend.tap()
        XCTAssertTrue(chatField.waitForExistence(timeout: 5), "Chat must be relocked after background")
        XCTAssertFalse(app.descendants(matching: .any)["local-draft-status"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.secureTextFields["App password"].waitForExistence(timeout: 10), "Relaunch must require app password")
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
    }
}
