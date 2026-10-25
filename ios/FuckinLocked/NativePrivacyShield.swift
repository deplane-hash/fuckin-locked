import SwiftUI
import UIKit

// An opaque scene window is shown synchronously on UIKit's inactive event,
// including over presented sheets. SwiftUI's view replacement is a second layer.
// Physical-device snapshot timing remains a release verification requirement.
struct NativePrivacyShield: UIViewRepresentable {
    let onInactive: () -> Void

    func makeUIView(context: Context) -> ShieldAnchor {
        let anchor = ShieldAnchor()
        // This view only locates the scene. It must never intercept touches
        // intended for password controls in a pushed hosting controller.
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        anchor.onInactive = onInactive
        return anchor
    }

    func updateUIView(_ uiView: ShieldAnchor, context: Context) {
        uiView.onInactive = onInactive
    }

    static func dismantleUIView(_ uiView: ShieldAnchor, coordinator: ()) {
        uiView.stop()
    }
}

@MainActor final class ShieldAnchor: UIView {
    var onInactive: (() -> Void)?
    private var shield: UIWindow?
    private var observers: [NSObjectProtocol] = []

    var isCoverVisible: Bool { shield?.isHidden == false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard shield == nil, let scene = window?.windowScene else { return }
        let cover = NonKeyShieldWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 18/255, alpha: 1)
        let label = UILabel()
        label.text = "fuckin locked"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        controller.view.accessibilityViewIsModal = true
        cover.rootViewController = controller
        cover.isHidden = true
        shield = cover
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.conceal() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealIfActive() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: scene, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealIfActive() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: scene, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.conceal() }
        })
        if scene.activationState != .foregroundActive {
            // Attaching a representable can happen after the app notification
            // but before scene activation. Initial construction only covers:
            // root lifecycle handlers already invalidate the vault. Publishing
            // another lock here would mutate SwiftUI during its render.
            cover.isHidden = false
            window?.rootViewController?.view.accessibilityElementsHidden = true
        }
        // Settle a missed initial activation without ever revealing an
        // inactive scene. Real inactive notifications remain synchronous.
        DispatchQueue.main.async { [weak self] in self?.revealIfActive() }
    }

    private func revealIfActive() {
        guard UIApplication.shared.applicationState == .active,
              window?.windowScene?.activationState == .foregroundActive else { return }
        shield?.isHidden = true
        window?.rootViewController?.view.accessibilityElementsHidden = false
        window?.makeKey()
    }

    private func conceal() {
        shield?.isHidden = false
        window?.rootViewController?.view.accessibilityElementsHidden = true
        onInactive?()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        shield?.isHidden = true
        shield = nil
    }
}

private final class NonKeyShieldWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}
