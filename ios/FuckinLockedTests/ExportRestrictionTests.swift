import UIKit
import XCTest
@testable import FuckinLocked

@MainActor final class ExportRestrictionTests: XCTestCase {
    func testComposerDisablesCopyCutDragAndWritingTools() {
        let field = PrivateComposerTextField()
        field.text = "private draft"
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        XCTAssertEqual(field.writingToolsBehavior, .none)
        XCTAssertFalse(field.textDragInteraction?.isEnabled ?? false)
        XCTAssertFalse(field.interactions.contains { $0 is UIDropInteraction })
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
        XCTAssertEqual(field.accessibilityLabel, "Message")
    }

    func testThirdPartyKeyboardExtensionIsNotAllowed() {
        let delegate = KeyboardPolicyDelegate()
        XCTAssertFalse(delegate.application(.shared, shouldAllowExtensionPointIdentifier: .keyboard))
    }
}
