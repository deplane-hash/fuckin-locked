import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let privateNotificationOpened = Notification.Name("FLPrivateNotificationOpened")
}

@MainActor final class PrivateNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PrivateNotifications()
    @Published private(set) var token = ""
    @Published private(set) var revision = 0
    @Published private(set) var status = "Notifications are not enabled"
    private var uploadedFor = ""

    func resumeRegistration() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func request() async {
        UNUserNotificationCenter.current().delegate = self
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard allowed else { status = "Notifications are not allowed in iPhone Settings"; return }
            status = "Completing notification setup"
            UIApplication.shared.registerForRemoteNotifications()
        } catch { status = "Notifications are unavailable" }
    }

    func received(_ data: Data) {
        guard (32...100).contains(data.count) else { registrationFailed(); return }
        token = data.map { String(format: "%02x", $0) }.joined()
        uploadedFor = ""
        revision &+= 1
        status = "Completing notification setup"
    }

    func registrationFailed() { status = "Notifications require a push-enabled signed app" }

    func upload(vault: LocalVault, gateway: Gateway) async {
        guard vault.isUnlocked, !vault.deviceID.isEmpty, !token.isEmpty else { return }
        let device = vault.deviceID
        let current = token
        guard uploadedFor != device + current else { return }
        do {
            try await gateway.login(deviceID: device)
            guard vault.isUnlocked, vault.deviceID == device, token == current else { return }
            try await gateway.registerNotifications(current)
            guard vault.isUnlocked, vault.deviceID == device, token == current else { return }
            uploadedFor = device + current
            status = "Enabled · previews always say New message"
        } catch { status = "Notifications need setup. Open chats to receive messages." }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .privateNotificationOpened, object: nil)
            completion()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        // Only the fixed generic payload can surface in the foreground.
        completion(content.title.isEmpty && content.subtitle.isEmpty && content.body == "New message" &&
                   content.attachments.isEmpty && content.categoryIdentifier.isEmpty ? [.banner, .sound] : [])
    }
}

struct NotificationsView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @ObservedObject private var notifications = PrivateNotifications.shared
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Notifications only say “New message.” Names, message text, group names and media never appear.")
                Text("Tapping a notification opens the locked app. Messages decrypt only after both passwords.")
                Text(notifications.status).foregroundStyle(Palette.muted)
                PrimaryButton(title: "Enable notifications") {
                    Task {
                        await notifications.request()
                        await notifications.upload(vault: vault, gateway: gateway)
                    }
                }
                Spacer()
            }.padding(22).navigationTitle("Notifications")
                .background(Palette.background).foregroundStyle(Palette.text)
        }
    }
}
