import SwiftUI
import UIKit

final class KeyboardPolicyDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PrivateNotifications.shared.resumeRegistration()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        PrivateNotifications.shared.received(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PrivateNotifications.shared.registrationFailed()
    }

    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        identifier != .keyboard
    }
}

final class PrivateComposerTextField: UITextField, UITextDropDelegate {
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        placeholder = "Message"
        accessibilityLabel = "Message"
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        spellCheckingType = .no
        textContentType = nil
        writingToolsBehavior = .none
        textDragInteraction?.isEnabled = false
        textDropDelegate = self
        if let drop = textDropInteraction { removeInteraction(drop) }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { return nil }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Importing text is allowed; no edit-menu or keyboard action may
        // export the private draft to another application or writing service.
        action == #selector(paste(_:)) && super.canPerformAction(action, withSender: sender)
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        UITextDropProposal(operation: .cancel)
    }
}

struct PrivateMessageField: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PrivateComposerTextField {
        let field = PrivateComposerTextField()
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: PrivateComposerTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PrivateComposerTextField,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240,
               height: max(44, (uiView.font?.lineHeight ?? 22) + 16))
    }

    static func dismantleUIView(_ field: PrivateComposerTextField, coordinator: Coordinator) {
        field.text = ""
        field.resignFirstResponder()
        field.removeTarget(coordinator, action: nil, for: .allEvents)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PrivateMessageField
        init(_ parent: PrivateMessageField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
    }
}
