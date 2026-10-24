import XCTest

final class LockLifecycleTests: XCTestCase {
    func testBackgroundAndRelaunchRequireAppAndChatPasswords() throws {
        let app = XCUIApplication()
        app.launch()
        let appPassword = "uitest app password"
        let chatPassword = "uitest chat password"
        let create = app.buttons["Create password"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        let firstPassword = app.secureTextFields["App password · 12 characters minimum"]
        firstPassword.tap(); firstPassword.typeText(appPassword)
        let repeatPassword = app.secureTextFields["Repeat password"]
        repeatPassword.tap(); repeatPassword.typeText(appPassword)
        create.tap()
        let compose = app.buttons["Compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Lifecycle test friend")
        let separate = app.secureTextFields["Separate chat password"]
        separate.tap(); separate.typeText(chatPassword)
        app.buttons["Create locked draft"].tap()
        let friend = app.staticTexts["Lifecycle test friend"].firstMatch
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        friend.tap()
        let chatField = app.secureTextFields["Chat password"]
        XCTAssertTrue(chatField.waitForExistence(timeout: 5))
        chatField.tap(); chatField.typeText(chatPassword)
        app.buttons["Unlock chat"].tap()
        XCTAssertTrue(app.staticTexts["Local draft — delivery is not configured"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        let unlock = app.secureTextFields["App password"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
        unlock.tap(); unlock.typeText(appPassword)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        friend.tap()
        XCTAssertTrue(chatField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Local draft — delivery is not configured"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.secureTextFields["App password"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Lifecycle test friend"].exists)
    }
}
