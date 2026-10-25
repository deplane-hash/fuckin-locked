import XCTest
import UIKit
@testable import FuckinLocked

@MainActor final class NativePrivacyShieldTests: XCTestCase {
    func testSceneActivationReleasesCoverAndDeactivationLocksSynchronously() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let host = UIWindow(windowScene: scene)
        let controller = UIViewController()
        host.rootViewController = controller
        let anchor = ShieldAnchor(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        var locked = false
        anchor.onInactive = { locked = true }
        controller.view.addSubview(anchor)
        host.isHidden = false
        defer {
            anchor.stop()
            host.isHidden = true
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertTrue(locked, "Scene deactivation must invalidate state synchronously")
        XCTAssertTrue(anchor.isCoverVisible)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertFalse(anchor.isCoverVisible, "An active password screen must accept input")
        XCTAssertTrue(locked, "Releasing the cover must never authenticate or unlock the vault")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(anchor.isCoverVisible)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(anchor.isCoverVisible)
        XCTAssertTrue(locked)
    }
}
