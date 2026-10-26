import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import LibSignalClient

enum Palette {
    static let background = Color(red: 16/255, green: 18/255, blue: 18/255)
    static let surface = Color(red: 31/255, green: 34/255, blue: 33/255)
    static let lime = Color(red: 182/255, green: 246/255, blue: 83/255)
    static let text = Color(red: 247/255, green: 246/255, blue: 240/255)
    static let muted = Color(red: 174/255, green: 179/255, blue: 171/255)
}

@main struct FuckinLockedApp: App {
    @UIApplicationDelegateAdaptor(KeyboardPolicyDelegate.self) private var applicationDelegate
    @StateObject private var vault: LocalVault
    @StateObject private var gateway: Gateway
    @StateObject private var messaging: MessagingService

    init() {
        let vault = LocalVault()
        let gateway = Gateway()
        _vault = StateObject(wrappedValue: vault)
        _gateway = StateObject(wrappedValue: gateway)
        _messaging = StateObject(wrappedValue: MessagingService(vault: vault, gateway: gateway))
    }

    var body: some Scene {
        WindowGroup {
            PrivateRootView()
                .environmentObject(vault)
                .environmentObject(gateway)
                .environmentObject(messaging)
        }
    }
}

private struct PrivateRootView: View {
    @EnvironmentObject private var vault: LocalVault
    @EnvironmentObject private var gateway: Gateway
    @EnvironmentObject private var messaging: MessagingService
    @Environment(\.scenePhase) private var phase
    @Environment(\.isSceneCaptured) private var captured
    @State private var forceCover = false
    @ObservedObject private var notifications = PrivateNotifications.shared

    var body: some View {
            ZStack {
                Palette.background.ignoresSafeArea()
                if forceCover || phase != .active || captured {
                    PrivacyCover()
                } else if !vault.isConfigured {
                    CreatePasswordView()
                } else if !vault.isUnlocked {
                    AppUnlockView()
                } else {
                    MainView()
                }
            }
            .background(NativePrivacyShield {
                forceCover = true
                gateway.disconnect()
                vault.lockApp()
            }.allowsHitTesting(false).accessibilityHidden(true))
            .preferredColorScheme(.dark)
            .onChange(of: phase) { _, newPhase in
                if newPhase != .active { gateway.disconnect(); vault.lockApp() }
                else { forceCover = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                forceCover = true
                gateway.disconnect()
                vault.lockApp()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                forceCover = false
            }
            .onChange(of: captured) { _, isCaptured in
                if isCaptured { gateway.disconnect(); vault.lockApp() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                vault.lockChat()
            }
            .onChange(of: vault.unlockedChatID) { _, value in
                if value == nil { messaging.clearTransientState() }
            }
            .task(id: "\(vault.isUnlocked):\(vault.deviceID):\(notifications.revision)") {
                await notifications.upload(vault: vault, gateway: gateway)
            }
            .onReceive(NotificationCenter.default.publisher(for: .privateNotificationOpened)) { _ in
                gateway.disconnect(); vault.lockApp()
            }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34))
            Text("fuckin locked").font(.title2.bold())
        }
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.background)
        .background(Palette.lime, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct PasswordLayout<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "lock").font(.system(size: 36, weight: .light)).foregroundStyle(Palette.lime)
                    .accessibilityHidden(true)
                Text(title).font(.largeTitle.bold()).foregroundStyle(Palette.text)
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                content
            }
            .frame(maxWidth: .infinity)
            .padding(26)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct CreatePasswordView: View {
    @EnvironmentObject var vault: LocalVault
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var error = ""
    var body: some View {
        PasswordLayout(title: "fuckin locked", subtitle: "Set a separate app password. You will need it every time you return.", content:
            VStack(spacing: 14) {
                SecureField("App password · 12 characters minimum", text: $password)
                    .textContentType(nil).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .flField()
                SecureField("Repeat password", text: $repeatPassword)
                    .textContentType(nil).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
                PrimaryButton(title: "Create password") {
                    guard password == repeatPassword else { error = "Passwords do not match"; return }
                    do { try vault.createAppPassword(password); password = ""; repeatPassword = "" }
                    catch { self.error = "Use at least 12 characters" }
                }
            })
        .onDisappear { password = ""; repeatPassword = "" }
    }
}

private struct AppUnlockView: View {
    @EnvironmentObject var vault: LocalVault
    @State private var password = ""
    @State private var error = ""
    @FocusState private var passwordFocused: Bool
    var body: some View {
        PasswordLayout(title: "fuckin locked", subtitle: "This app locks whenever you leave it.", content:
            VStack(spacing: 14) {
                SecureField("App password", text: $password)
                    .textContentType(nil).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().flField()
                    .focused($passwordFocused)
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
                PrimaryButton(title: "Unlock") {
                    do { try vault.unlock(password); password = ""; error = "" }
                    catch VaultError.delayed(let seconds) { error = "Try again in \(seconds) seconds" }
                    catch { self.error = "Password incorrect" }
                }
            })
        .onAppear {
            // Re-focus after the native privacy shield has covered and
            // uncovered the scene. This only targets the password field; it
            // never unlocks or retains authentication state.
            DispatchQueue.main.async { passwordFocused = true }
        }
        .onDisappear { password = ""; passwordFocused = false }
    }
}

private extension View {
    func flField() -> some View {
        self.padding(16).frame(minHeight: 52)
            .foregroundStyle(Palette.text)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .autocorrectionDisabled()
    }
}

private enum Destination: String, CaseIterable {
    case chats = "Chats", calls = "Calls", people = "People", you = "You"
    var symbol: String {
        switch self { case .chats: "bubble.left.and.bubble.right"; case .calls: "phone"; case .people: "person.2"; case .you: "person.crop.circle" }
    }
}

private struct MainView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @State private var selected: Destination = .chats
    var body: some View {
        NavigationStack {
            Group {
                switch selected {
                case .chats: ChatsView()
                case .calls: CallsView(openChats: { selected = .chats })
                case .people: PeopleView()
                case .you: YouView()
                }
            }
            .task(id: vault.deviceID) {
                guard !vault.deviceID.isEmpty else { return }
                try? await gateway.login(deviceID: vault.deviceID)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    ForEach(Destination.allCases, id: \.self) { item in
                        Button {
                            vault.lockChat()
                            selected = item
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: item.symbol).font(.system(size: 20))
                                Text(item.rawValue).font(.caption2)
                            }
                            .foregroundStyle(selected == item ? Palette.lime : Palette.muted)
                            .frame(maxWidth: .infinity).frame(minHeight: 54)
                        }
                    }
                }
                .padding(6).background(Palette.surface, in: Capsule())
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
    }
}

private struct CallsView: View {
    @EnvironmentObject private var vault: LocalVault
    let openChats: () -> Void
    private var eligible: [StoredChat] {
        vault.chats.filter { !$0.isGroup && $0.roomID != nil && $0.remoteDeviceID != nil }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Calls").font(.largeTitle.bold())
                Text("Unlock a verified one-to-one chat to call. Keep that chat open on both phones to receive the call.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if eligible.isEmpty {
                    Text("Create an encrypted chat before calling").foregroundStyle(Palette.muted)
                    PrimaryButton(title: "Open Chats", action: openChats)
                }
                ForEach(eligible) { chat in
                    NavigationLink(value: chat.id) {
                        HStack(spacing: 14) {
                            Text(String(chat.title.prefix(1))).font(.headline)
                                .frame(width: 48, height: 48).background(Palette.surface, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).font(.headline)
                                Text("Unlock to call").font(.subheadline).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "phone").foregroundStyle(Palette.lime)
                        }.padding(.vertical, 8)
                    }
                    Divider()
                }
            }.padding(22)
        }.navigationDestination(for: UUID.self) { ChatGateView(id: $0) }
            .background(Palette.background).foregroundStyle(Palette.text)
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ChatsView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @State private var activityRooms: Set<String> = []
    @State private var search = ""
    @State private var groupsOnly = false
    @State private var compose = false
    @State private var groupCompose = false
    var visible: [StoredChat] {
        vault.chats.filter { (!groupsOnly || $0.isGroup) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Chats").font(.largeTitle.bold())
                    Spacer()
                    Button { groupCompose = true } label: { Image(systemName: "person.2.badge.plus").font(.title3) }
                        .accessibilityLabel("Create or join private group")
                    Button { compose = true } label: { Image(systemName: "square.and.pencil").font(.title3) }
                        .accessibilityLabel("Compose")
                }
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Search chats", text: $search)
                }.foregroundStyle(Palette.muted).flField()
                HStack(spacing: 10) {
                    filter("All", selected: !groupsOnly) { groupsOnly = false }
                    filter("Groups", selected: groupsOnly) { groupsOnly = true }
                }
                if visible.isEmpty {
                    VStack(spacing: 10) {
                        Text(search.isEmpty ? "No chats yet" : "No matching chats")
                        if vault.deviceID.isEmpty && search.isEmpty {
                            Text("Open You to use an invitation or set up the first device. Then invite a friend in People.")
                                .font(.subheadline).multilineTextAlignment(.center)
                        }
                    }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 180)
                }
                ForEach(visible) { chat in
                    NavigationLink(value: chat.id) {
                        HStack(spacing: 13) {
                            Text(String(chat.title.prefix(1)).uppercased())
                                .font(.headline).foregroundStyle(Palette.background)
                                .frame(width: 48, height: 48)
                                .background(Palette.lime, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).foregroundStyle(Palette.text).font(.headline)
                                Text("Message hidden").foregroundStyle(Palette.muted).font(.subheadline)
                            }
                            Spacer()
                            if let room = chat.roomID, activityRooms.contains(room) {
                                Circle().fill(Palette.lime).frame(width: 7, height: 7)
                                    .accessibilityLabel("New activity")
                            }
                            Image(systemName: "lock.fill").foregroundStyle(Palette.muted).font(.caption)
                        }.padding(.vertical, 8)
                    }
                    Divider().overlay(Palette.surface)
                }
            }.padding(22)
        }
        .navigationDestination(for: UUID.self) { id in ChatGateView(id: id) }
        .sheet(isPresented: $compose) { ComposeView() }
        .sheet(isPresented: $groupCompose) { GroupComposeView() }
        .background(Palette.background)
        .foregroundStyle(Palette.text)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: vault.deviceID) {
            guard !vault.deviceID.isEmpty else { return }
            while !Task.isCancelled && vault.isUnlocked {
                do {
                    try await gateway.login(deviceID: vault.deviceID)
                    let rooms = try await gateway.inboxActivity()
                    guard vault.isUnlocked, !Task.isCancelled else { return }
                    activityRooms = rooms
                } catch { }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onDisappear { search = ""; activityRooms = [] }
    }

    private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 17).padding(.vertical, 9) }
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .background(selected ? Palette.lime : Palette.surface, in: Capsule())
    }
}

private struct ComposeView: View {
    private struct JoinableRoom: Identifiable {
        let room: RoomInfo
        let peer: RoomMember
        var id: String { room.id }
    }

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @State private var title = ""
    @State private var password = ""
    @State private var group = false
    @State private var error = ""
    @State private var people: [Person] = []
    @State private var rooms: [RoomInfo] = []
    @State private var selection = ""
    @State private var peerDevices: [RoomDevice] = []
    @State private var peerDeviceID = ""

    private var availablePeople: [Person] {
        people.filter { $0.id != vault.indexedUserID }
    }

    private var oneToOneRooms: [JoinableRoom] {
        rooms.compactMap { room in
            let peers = room.members.filter { $0.id != vault.indexedUserID }
            guard room.is_group != true, room.members.count == 2, let peer = peers.first else { return nil }
            return JoinableRoom(room: room, peer: peer)
        }
    }

    private var isEncryptedSelection: Bool {
        selection.hasPrefix("person:") || selection.hasPrefix("room:")
    }

    private var isLocalDraft: Bool { selection == "draft" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(isEncryptedSelection ? "Encrypted one-to-one" : isLocalDraft ? "Local draft chat" : "New chat")
                    .font(.headline)
                Text(isEncryptedSelection
                     ? "Messages use an end-to-end encrypted session after device verification."
                     : isLocalDraft ? "A local draft is stored only on this device."
                     : "Choose an approved friend and their device to start an encrypted conversation.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                if !availablePeople.isEmpty || !oneToOneRooms.isEmpty {
                    Picker("Conversation", selection: $selection) {
                        Text("Choose a friend").tag("")
                        if isLocalDraft { Text("Local draft").tag("draft") }
                        ForEach(availablePeople) { person in
                            Text("New · \(person.name) · @\(person.username)").tag("person:\(person.id)")
                        }
                        ForEach(oneToOneRooms) { item in
                            Text("Continue · \(item.peer.name)").tag("room:\(item.room.id)")
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                }
                if !isLocalDraft && !isEncryptedSelection {
                    if availablePeople.isEmpty && oneToOneRooms.isEmpty {
                        Text(vault.deviceID.isEmpty
                             ? "Join using an invitation in You first. Then approved friends appear here."
                             : "No approved friends yet. Invite a friend from People, then return here.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Button("Create a local draft instead") { selection = "draft" }
                        .font(.footnote)
                }
                TextField("Name", text: $title).flField()
                if isEncryptedSelection && !peerDevices.isEmpty {
                    Picker("Friend's device", selection: $peerDeviceID) {
                        Text("Select a device").tag("")
                        ForEach(peerDevices, id: \.id) { device in
                            Text(device.id).tag(device.id)
                        }
                    }.pickerStyle(.menu)
                    Text("Check the device ID with your friend. Each device needs its own fingerprint verification.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                if isLocalDraft {
                    Toggle("Group", isOn: $group).tint(Palette.lime)
                }
                SecureField("Separate chat password", text: $password).flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                PrimaryButton(title: isEncryptedSelection ? "Add encrypted chat" : isLocalDraft ? "Create locked draft" : "Choose a friend") {
                    Task {
                        do {
                            if isLocalDraft {
                                try vault.createChat(title: title, isGroup: group, password: password)
                            } else {
                                guard isEncryptedSelection else { throw MessagingError.invalidMessage }
                                try await gateway.login(deviceID: vault.deviceID)
                                let room: String
                                let peerID: String
                                let peerName: String
                                if selection.hasPrefix("person:") {
                                    peerID = String(selection.dropFirst("person:".count))
                                    room = try await gateway.createOneToOneRoom(with: peerID)
                                    guard let peer = availablePeople.first(where: { $0.id == peerID }) else {
                                        throw ConnectionError.invalidResponse
                                    }
                                    peerName = peer.name
                                } else {
                                    room = String(selection.dropFirst("room:".count))
                                    guard let item = oneToOneRooms.first(where: { $0.room.id == room }) else {
                                        throw ConnectionError.invalidResponse
                                    }
                                    peerID = item.peer.id
                                    peerName = item.peer.name
                                }
                                guard !vault.chats.contains(where: { $0.roomID == room }) else {
                                    throw MessagingError.invalidMessage
                                }
                                let devices = try await gateway.roomDevices(room)
                                guard let peer = devices.first(where: { $0.user_id == peerID && $0.id == peerDeviceID }) else {
                                    throw ConnectionError.invalidResponse
                                }
                                try vault.createChat(title: peerName.isEmpty ? title : peerName, isGroup: false,
                                                     password: password, roomID: room,
                                                     remoteUserID: peerID,
                                                     remoteDeviceID: peer.id)
                            }
                            dismiss()
                        } catch {
                            self.error = isLocalDraft
                                ? "Enter a name and a password of at least 12 characters"
                                : (error is MessagingError ? "This room is already on this device" : "Can't connect or create this chat")
                        }
                    }
                }
                .disabled(!isLocalDraft && (!isEncryptedSelection || peerDeviceID.isEmpty))
                Spacer()
            }.padding(22).background(Palette.background).foregroundStyle(Palette.text)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .task {
            guard !vault.deviceID.isEmpty else { return }
            try? await gateway.login(deviceID: vault.deviceID)
            people = (try? await gateway.people()) ?? []
            rooms = (try? await gateway.rooms()) ?? []
        }
        .task(id: selection) {
            peerDevices = []; peerDeviceID = ""
            let userID: String
            if selection.hasPrefix("person:") {
                userID = String(selection.dropFirst("person:".count))
            } else if selection.hasPrefix("room:"),
                      let item = oneToOneRooms.first(where: { $0.room.id == String(selection.dropFirst("room:".count)) }) {
                userID = item.peer.id
            } else { return }
            do {
                peerDevices = try await gateway.memberDevices(userID)
                try Task.checkCancellation()
                if peerDevices.count == 1 { peerDeviceID = peerDevices[0].id }
            } catch { self.error = "Can't load approved devices" }
        }
        .onDisappear { title = ""; password = ""; selection = ""; rooms.removeAll(keepingCapacity: false) }
    }
}

private struct ChatGateView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var password = ""
    @State private var error = ""
    // Keep the successful transition local to this gate as well as in the
    // vault. This prevents SwiftUI from briefly rebuilding the password
    // branch while the encrypted payload is being opened.
    @State private var unlocked = false
    @FocusState private var passwordFocused: Bool
    var title: String { vault.chats.first(where: { $0.id == id })?.title ?? "Chat" }
    var body: some View {
        Group {
            if unlocked && vault.unlockedChatID == id {
                if let chat = vault.chats.first(where: { $0.id == id }), chat.isGroup, chat.roomID != nil {
                    GroupConversationView(id: id, title: title, vault: vault, gateway: gateway)
                } else { ConversationView(id: id, title: title) }
            } else {
                PasswordLayout(title: title, subtitle: "This chat has a separate password.", content:
                    VStack(spacing: 14) {
                        SecureField("Chat password", text: $password).flField()
                            .focused($passwordFocused)
                        if !error.isEmpty { Text(error).foregroundStyle(.red) }
                        PrimaryButton(title: "Unlock chat") {
                            do {
                                try vault.unlockChat(id, password: password)
                                unlocked = true
                                password = ""
                            }
                            catch VaultError.delayed(let seconds) { error = "Try again in \(seconds) seconds" }
                            catch { self.error = "Password incorrect" }
                        }
                    })
            }
        }
        .background(Palette.background)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Close") { vault.lockChat(); dismiss() }
        }}
        .onAppear {
            unlocked = vault.unlockedChatID == id
            DispatchQueue.main.async { passwordFocused = true }
        }
        // ConversationView owns relocking when the conversation actually
        // leaves the navigation stack. Do not relock from this gate's
        // lifecycle: SwiftUI can tear down the password branch while it is
        // replacing it with the unlocked conversation, which would make a
        // successful unlock immediately disappear.
        .onDisappear { password = ""; passwordFocused = false }
    }
}

private struct ConversationView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var messaging: MessagingService
    @EnvironmentObject var gateway: Gateway
    let id: UUID
    let title: String
    @State private var draft = ""
    @State private var drawer = false
    @State private var showChangePassword = false
    @State private var showEncryptedCompose = false
    @State private var fingerprint = ""
    @State private var ownFingerprint = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var viewedImage: Data?
    @State private var viewedFile: PrivateAttachment?
    @State private var attachmentChoices = false
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var fileGeneration: UInt64 = 0
    @State private var verified = false
    @State private var identityMismatch = false
    @State private var status = ""
    @State private var callController: VoiceCallCoordinator?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let chat = try? vault.chatMetadata(for: id), !chat.isGroup,
                   let callController {
                    VoiceCallControls(controller: callController, canStart: verified && !identityMismatch)
                }
                Button { showChangePassword = true } label: { Image(systemName: "key") }
                    .accessibilityLabel("Change chat password")
                Button("Lock chat") { callController?.stop(); draft = ""; vault.lockChat() }
                    .foregroundStyle(Palette.lime)
            }.padding(.horizontal)
            if vault.chats.first(where: { $0.id == id })?.roomID == nil {
                Text("Local draft — delivery is not configured")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Local draft delivery is not configured")
                    .accessibilityIdentifier("local-draft-status")
                Text("This draft stays on this iPhone. Create an encrypted chat from Chats to message an approved friend.")
                    .font(.footnote).foregroundStyle(Palette.muted).padding(.horizontal)
                Button("Create encrypted chat") { showEncryptedCompose = true }
                    .font(.subheadline).foregroundStyle(Palette.lime)
            }
            if !ownFingerprint.isEmpty && !verified {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your fingerprint").font(.headline)
                    Text("Your friend compares this with the fingerprint shown for you on their phone.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                    Text(ownFingerprint).font(.caption2.monospaced()).textSelection(.disabled)
                }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
            }
            if !fingerprint.isEmpty && !verified && !identityMismatch {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verify this device before sending")
                        .font(.headline)
                    Text("Compare this fingerprint with your friend in another trusted channel.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                    Text(fingerprint).font(.caption2.monospaced())
                        .foregroundStyle(Palette.lime).textSelection(.disabled)
                    Button("I verified this fingerprint") {
                        do {
                            try messaging.verifyPeer(for: id)
                            verified = true
                            status = "Device verified"
                        } catch { status = "Verification failed" }
                    }.foregroundStyle(Palette.lime)
                }
                .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vault.messageRecords.filter { $0.reactionTarget == nil && $0.callSignal == nil }) { message in
                        HStack {
                            if message.isOutgoing { Spacer(minLength: 36) }
                            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                                if let bytes = message.image {
                                    Button { viewedImage = bytes } label: {
                                        PrivateMediaImage(data: bytes).frame(width: 220, height: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }.accessibilityLabel("View image")
                                }
                                if let file = message.file {
                                    Button {
                                        if file.format == .audio || file.format == .video { callController?.stop() }
                                        viewedFile = file
                                    } label: {
                                        Label(file.name, systemImage: "doc").padding(10)
                                    }.accessibilityLabel("Open attachment \(file.name)")
                                }
                                if !message.body.isEmpty {
                                    Text(message.body).font(vault.preferences.largerMessages ? .title3 : .body).padding(11)
                                        .foregroundStyle(message.isOutgoing ? Palette.background : Palette.text)
                                        .background(message.isOutgoing ? Palette.lime : Palette.surface,
                                                    in: RoundedRectangle(cornerRadius: 16))
                                }
                                if let reactions = message.reactions, !reactions.isEmpty {
                                    Text(reactions.sorted { $0.key < $1.key }.map(\.value).joined(separator: " "))
                                        .accessibilityLabel("Reactions \(reactions.values.joined(separator: " "))")
                                }
                                Menu {
                                    ForEach(MessageContent.reactions, id: \.self) { reaction in
                                        Button(reaction) {
                                            Task {
                                                do { try await messaging.react(reaction, to: message.id, in: id) }
                                                catch { status = "Can't send reaction" }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "face.smiling").frame(minWidth: 44, minHeight: 44)
                                }.disabled(!verified || messaging.working)
                                    .accessibilityLabel("React to message")
                                if message.isOutgoing {
                                    Text(message.delivery == .delivered ? "Delivered" :
                                         message.delivery == .accepted ? "Sent" : "Waiting to send")
                                        .font(.caption2).foregroundStyle(Palette.muted)
                                }
                                Text(message.sentAt, style: .time).font(.caption2).foregroundStyle(Palette.muted)
                            }
                            if !message.isOutgoing { Spacer(minLength: 36) }
                        }
                    }
                }.padding(.horizontal)
            }
            if !status.isEmpty, vault.chats.first(where: { $0.id == id })?.roomID != nil {
                Text(status).font(.caption).foregroundStyle(Palette.muted)
            }
            if let callController { VoiceCallStatus(controller: callController) }
            HStack(spacing: 12) {
                Button { drawer.toggle() } label: { Image(systemName: "face.smiling") }
                    .accessibilityLabel("Stickers and emoji")
                PrivateMessageField(text: $draft, isEnabled: verified && !identityMismatch)
                    .frame(minHeight: 44)
                Button {
                    let outgoing = draft
                    let generation = vault.chatGeneration
                    draft = ""
                    Task {
                        do { try await messaging.send(outgoing, in: id) }
                        catch MessagingError.identityVerificationRequired(let value) {
                            guard vault.chatGeneration == generation else { return }
                            fingerprint = value; verified = false; status = "Verify the device first"; draft = outgoing
                        }
                        catch MessagingError.queued {
                            guard vault.chatGeneration == generation else { return }
                            status = "Saved. Waiting for a connection."
                        }
                        catch {
                            guard vault.chatGeneration == generation else { return }
                            status = "Can't send this message"
                            draft = outgoing
                        }
                    }
                } label: { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(!verified || messaging.working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
                Button { attachmentChoices = true } label: {
                    Image(systemName: "paperclip").frame(minWidth: 44, minHeight: 44)
                }.disabled(!verified || messaging.working).accessibilityLabel("Attach media or file")
            }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("message-composer")
                .padding(.horizontal)
            if drawer {
                StickerDrawer(id: id, insert: { draft += $0 }, sendSticker: { sticker in
                    Task {
                        do { try await messaging.sendImage(sticker.imageData(), in: id) }
                        catch { status = "Sticker saved for retry or unavailable" }
                    }
                }, close: { drawer = false })
            }
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .overlay {
            if let viewedImage {
                VStack {
                    Button("Close image") { self.viewedImage = nil }.padding()
                    Spacer()
                    PrivateMediaImage(data: viewedImage).accessibilityLabel("Message image")
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background).ignoresSafeArea(edges: .bottom)
            }
        }
        .confirmationDialog("Attachment", isPresented: $attachmentChoices) {
            Button("Photo or GIF") { photoPicker = true }
            Button("File or short media clip") { fileGeneration = vault.chatGeneration; filePicker = true }
        }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current)
        .sheet(item: $viewedFile) { file in PrivateAttachmentView(attachment: file) { viewedFile = nil } }
        .sheet(isPresented: $filePicker) {
            StickerPackPicker(allowedTypes: [.pdf, .plainText, .wav, .mpeg4Audio, .mp3, .mpeg4Movie, .quickTimeMovie]) { result in
                filePicker = false
                let generation = fileGeneration
                Task {
                    do {
                        let url = try result.get()
                        let file = try await Task.detached(priority: .userInitiated) { try PrivateAttachment.read(url) }.value
                        guard vault.unlockedChatID == id, vault.chatGeneration == generation else { return }
                        try await messaging.sendFile(file, in: id)
                    } catch MessagingError.queued {
                        guard vault.chatGeneration == generation else { return }
                        status = "Saved. Waiting for a connection."
                    } catch {
                        guard vault.chatGeneration == generation else { return }
                        status = "Can't send this file. Supported files are limited to 512 KB."
                    }
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            let generation = vault.chatGeneration
            Task {
                defer { selectedPhoto = nil }
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self),
                          vault.chatGeneration == generation else { return }
                    let image = try await Task.detached(priority: .userInitiated) { try PrivateImage.importMedia(bytes) }.value
                    guard vault.chatGeneration == generation else { return }
                    try await messaging.sendImage(image, in: id)
                } catch {
                    guard vault.chatGeneration == generation else { return }
                    status = "Image unavailable or connection interrupted. Saved messages retry automatically."
                }
            }
        }
        .sheet(isPresented: $showChangePassword) { ChangeChatPasswordView(id: id) }
        .sheet(isPresented: $showEncryptedCompose) { ComposeView() }
        .task {
            let generation = vault.chatGeneration
            // Local drafts never enter the relay or libsignal path. Surface
            // that boundary immediately instead of waiting for a network
            // operation to report localChatOnly.
            if vault.chats.first(where: { $0.id == id })?.roomID == nil {
                status = "Local draft — delivery is not configured"
                return
            }
            if callController == nil, let chat = try? vault.chatMetadata(for: id), !chat.isGroup {
                callController = VoiceCallCoordinator(id: id, vault: vault,
                                                       gateway: gateway, messaging: messaging)
            }
            verified = (try? messaging.isPeerVerified(for: id)) ?? false
            while !Task.isCancelled && vault.chatGeneration == generation && vault.unlockedChatID == id {
                do {
                    if !messaging.working {
                        if !verified {
                            fingerprint = try await messaging.preparePeerVerification(for: id)
                            verified = try messaging.isPeerVerified(for: id)
                        } else {
                            try await messaging.receive(in: id)
                        }
                        callController?.consume(vault.messageRecords)
                        guard vault.chatGeneration == generation else { return }
                        ownFingerprint = (try? messaging.ownFingerprint(for: id)) ?? ""
                        status = ""
                    }
                } catch SignalError.untrustedIdentity(_) {
                    callController?.stop(sendHangup: false)
                    verified = false; identityMismatch = true
                    status = "Device identity changed. Messaging stopped. Compare identities with your friend before starting a new verified chat."
                    return
                } catch SignalStoreError.identityChanged {
                    callController?.stop(sendHangup: false)
                    verified = false; identityMismatch = true
                    status = "Device identity changed. Messaging stopped."
                    return
                } catch MessagingError.localChatOnly {
                    status = "Local draft — delivery is not configured"
                    return
                } catch MessagingError.identityVerificationRequired(let value) {
                    fingerprint = value; verified = false
                } catch {
                    guard vault.chatGeneration == generation else { return }
                    callController?.stop(sendHangup: false)
                    ownFingerprint = (try? messaging.ownFingerprint(for: id)) ?? ""
                    status = "Can't connect. Retrying while this chat is open."
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onDisappear {
            draft = ""; fingerprint = ""; ownFingerprint = ""; drawer = false
            selectedPhoto = nil; viewedImage = nil; viewedFile = nil; callController?.close()
            callController = nil; vault.lockChat()
        }
    }
}

struct ChangeChatPasswordView: View {
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var old = ""
    @State private var new = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SecureField("Current chat password", text: $old).flField()
                SecureField("New chat password · 12 characters minimum", text: $new).flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                PrimaryButton(title: "Change chat password") {
                    do { try vault.changeChatPassword(id, old: old, new: new); dismiss() }
                    catch { self.error = "Password change failed" }
                }
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("Chat password")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onDisappear { old = ""; new = "" }
    }
}

struct StickerDrawer: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var messaging: MessagingService
    let id: UUID
    let insert: (String) -> Void
    let sendSticker: (StarterSticker) -> Void
    let close: () -> Void
    init(id: UUID, insert: @escaping (String) -> Void,
         sendSticker: @escaping (StarterSticker) -> Void, close: @escaping () -> Void) {
        self.id = id; self.insert = insert; self.sendSticker = sendSticker; self.close = close
    }
    @State private var search = ""
    @State private var library = ComposerLibrary()
    @State private var selected = "All"
    @State private var tab = "Stickers"
    @State private var pack = "All packs"
    @State private var importing = false
    @State private var importGeneration: UInt64 = 0
    @State private var importStatus = ""
    @State private var showPackCredits = false
    @State private var persistenceEnabled = false
    private var allStickers: [StarterSticker] {
        StarterStickers.items + (library.importedPacks ?? []).flatMap(\.items)
    }
    private let items = [
        ("🙂", "smile happy"), ("😄", "laugh happy"), ("💚", "green heart love"),
        ("✨", "sparkles stars"), ("🔥", "fire hot"), ("🙌", "hands celebrate"),
        ("🎉", "party celebration"), ("🌙", "moon night"), ("🐈", "cat animal"),
        ("🦊", "fox animal"), ("🪐", "planet space"), ("🍋", "lemon fruit")
    ]
    private var visible: [(String, String)] {
        let source = selected == "Recent" ? library.recentEmoji.compactMap { value in items.first { $0.0 == value } } : items
        return source.filter {
            (selected != "Favorites" || library.favoriteEmoji.contains($0.0)) &&
            (search.isEmpty || $0.1.localizedCaseInsensitiveContains(search) || $0.0 == search)
        }
    }
    private var stickers: [StarterSticker] {
        let source = selected == "Recent" ? library.recentStickers.compactMap { key in
            allStickers.first { $0.id == key }
        } : allStickers
        return source.filter {
            (selected != "Favorites" || library.favoriteStickers.contains($0.id)) &&
            (tab != "GIFs" || $0.isAnimated) &&
            (pack == "All packs" || pack == $0.pack) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.tags.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Palette.muted).frame(width: 36, height: 4)
            HStack {
                Text(tab).font(.headline)
                Spacer()
                Button("Close", action: close)
            }
            TextField("Search locally", text: $search).flField()
            Picker("Content type", selection: $tab) {
                Text("Stickers").tag("Stickers")
                Text("GIFs").tag("GIFs")
                Text("Emoji").tag("Emoji")
            }.pickerStyle(.segmented)
            Picker("Emoji collection", selection: $selected) {
                ForEach(["All", "Recent", "Favorites"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            if tab != "Emoji" {
                Button("Import sticker pack") {
                    importGeneration = vault.chatGeneration
                    importing = true
                }.foregroundStyle(Palette.lime)
                if !(library.importedPacks ?? []).isEmpty {
                    Button("Pack credits") { showPackCredits = true }.foregroundStyle(Palette.lime)
                }
                if !importStatus.isEmpty {
                    Text(importStatus).font(.caption).foregroundStyle(Palette.muted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["All packs"] + Array(Set(allStickers.map(\.pack))).sorted(), id: \.self) { title in
                            Button(title) { pack = title }
                                .padding(10).foregroundStyle(pack == title ? Palette.lime : Palette.muted)
                        }
                    }
                }
            }
            ScrollView {
                if tab != "Emoji" {
                    if stickers.isEmpty {
                        Text(tab == "GIFs" ? "Import a version 3 GIF pack to add local animations. Searches stay on this iPhone." : "No matching stickers")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(stickers) { sticker in
                            VStack {
                                Button {
                                    sendSticker(sticker)
                                    if vault.preferences.haptics { UISelectionFeedbackGenerator().selectionChanged() }
                                    library.recentStickers.removeAll { $0 == sticker.id }
                                    library.recentStickers.insert(sticker.id, at: 0)
                                } label: {
                                    if let bytes = try? sticker.imageData() {
                                        PrivateMediaImage(data: bytes).frame(width: 80, height: 80)
                                    }
                                }.disabled(messaging.working).accessibilityLabel("Send \(sticker.title) sticker")
                                Button {
                                    if library.favoriteStickers.contains(sticker.id) { library.favoriteStickers.remove(sticker.id) }
                                    else { library.favoriteStickers.insert(sticker.id) }
                                } label: {
                                    Image(systemName: library.favoriteStickers.contains(sticker.id) ? "star.fill" : "star")
                                        .frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("Favorite \(sticker.title)")
                            }
                        }
                    }
                } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(visible, id: \.0) { item in
                        VStack(spacing: 0) {
                            Button {
                                insert(item.0)
                                library.recentEmoji.removeAll { $0 == item.0 }
                                library.recentEmoji.insert(item.0, at: 0)
                            } label: { Text(item.0).font(.largeTitle).frame(minHeight: 48) }
                                .accessibilityLabel("Insert \(item.1)")
                            Button {
                                if library.favoriteEmoji.contains(item.0) { library.favoriteEmoji.remove(item.0) }
                                else { library.favoriteEmoji.insert(item.0) }
                            } label: {
                                Image(systemName: library.favoriteEmoji.contains(item.0) ? "star.fill" : "star")
                                    .frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("Favorite \(item.1)")
                        }
                    }
                }
                }
            }.frame(maxHeight: 240)
        }.padding().background(Palette.surface, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .task {
                library = (try? vault.composerLibrary(for: id)) ?? ComposerLibrary()
                persistenceEnabled = true
            }
            .onChange(of: library) { _, value in
                guard persistenceEnabled else { return }
                do { try vault.saveComposerLibrary(value, for: id) }
                catch { importStatus = "Couldn't save sticker preferences" }
            }
            .sheet(isPresented: $showPackCredits) {
                NavigationStack {
                    List(library.importedPacks ?? []) { imported in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(imported.name).font(.headline)
                            Text(imported.author)
                            Text(imported.license).font(.footnote)
                        }
                    }.navigationTitle("Pack credits")
                        .toolbar { Button("Done") { showPackCredits = false } }
                }
            }
            .sheet(isPresented: $importing) {
                StickerPackPicker { result in
                importing = false
                let generation = importGeneration
                Task {
                    do {
                        let url = try result.get()
                        let imported = try await Task.detached(priority: .userInitiated) { try StickerPack.read(url) }.value
                        guard vault.unlockedChatID == id, vault.chatGeneration == generation else { return }
                        var updated = library
                        try updated.add(imported)
                        try vault.saveComposerLibrary(updated, for: id)
                        library = updated
                        importStatus = "Imported \(imported.name). \(imported.author) · \(imported.license)"
                    } catch {
                        guard vault.chatGeneration == generation else { return }
                        importStatus = "Can't import this pack. Use a bounded version 2 or 3 pack."
                    }
                }
                }
            }
            .onDisappear {
                persistenceEnabled = false
                library = ComposerLibrary(); search = ""; importStatus = ""
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { if $0.translation.height > 60 { close() } })
    }
}

private struct PeopleView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @State private var people: [Person] = []
    @State private var error = ""
    @State private var invitation = ""
    @State private var admissions: [PendingAdmission] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("People").font(.largeTitle.bold())
                if !error.isEmpty { Text(error).foregroundStyle(Palette.muted) }
                if !invitation.isEmpty {
                    Text("Invitation code").font(.headline)
                    Text(invitation).font(.body.monospaced()).textSelection(.disabled)
                    PairingQRCode(value: invitation, kind: .invitation)
                    Text("Give this code to your friend privately. It expires and needs approval.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                PrimaryButton(title: "Invite a friend") {
                    Task { do { invitation = try await gateway.invite() }
                        catch { self.error = "Can't connect" } }
                }.disabled(vault.deviceID.isEmpty)
                if !admissions.isEmpty { Text("Approval requests").font(.headline) }
                ForEach(admissions) { admission in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(admission.name)
                            Text("@\(admission.username)").font(.footnote).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Approve") {
                            Task {
                                do {
                                    try await gateway.approveAdmission(admission.id)
                                    admissions = try await gateway.pendingAdmissions()
                                    people = try await gateway.people()
                                } catch { self.error = "Can't connect" }
                            }
                        }.foregroundStyle(Palette.lime)
                    }.padding(.vertical, 8)
                }
                ForEach(people) { person in
                    HStack {
                        Text(String(person.name.prefix(1))).frame(width: 44, height: 44)
                            .background(Palette.surface, in: Circle())
                        VStack(alignment: .leading) {
                            Text(person.name)
                            Text("@\(person.username)").font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }.padding(22)
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .task(id: vault.deviceID) {
            guard !vault.deviceID.isEmpty else { error = "Finish your invitation to connect"; return }
            while !Task.isCancelled && vault.isUnlocked {
                do {
                    try await gateway.login(deviceID: vault.deviceID)
                    let approved = try await gateway.people()
                    let pending = try await gateway.pendingAdmissions()
                    guard vault.isUnlocked, !Task.isCancelled else { return }
                    people = approved; admissions = pending; error = ""
                } catch { self.error = "Can't connect" }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onDisappear {
            people.removeAll(keepingCapacity: false)
            admissions.removeAll(keepingCapacity: false)
            invitation = ""
        }
    }
}

private struct YouView: View {
    @EnvironmentObject var vault: LocalVault
    @State private var showPassword = false
    @State private var showPrivacy = false
    @State private var showNotifications = false
    @State private var showProfile = false
    @State private var showInvite = false
    @State private var showDevices = false
    @State private var showEnrollment = false
    @State private var showBootstrap = false
    @State private var showPairing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("You").font(.largeTitle.bold())
                Text("Messages decrypt only in unlocked chats. Calls require both participants to keep the chat open.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                HStack(spacing: 14) {
                    if let bytes = vault.profileAvatar, let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 58, height: 58).clipShape(Circle())
                            .accessibilityLabel("Your local avatar")
                    } else {
                        Text(String(vault.profileName.prefix(1))).font(.title)
                            .frame(width: 58, height: 58).background(Palette.surface, in: Circle())
                    }
                    VStack(alignment: .leading) {
                        Text(vault.profileName).font(.headline)
                        Text(vault.username.isEmpty ? "Not enrolled" : "@\(vault.username)")
                            .foregroundStyle(Palette.muted)
                    }
                }
                VStack(spacing: 0) {
                    row("Profile and appearance", "person.crop.circle") { showProfile = true }
                    row("Change app password", "key") { showPassword = true }
                    row("Authorized devices", "iphone") { showDevices = true }
                    row("Privacy protections", "hand.raised") { showPrivacy = true }
                    row("Notifications", "bell") { showNotifications = true }
                    if !vault.deviceID.isEmpty {
                        row("Invite a friend", "envelope") { showInvite = true }
                    }
                    if vault.deviceID.isEmpty {
                        row("Use invitation", "envelope") { showEnrollment = true }
                        row("First device setup", "iphone.gen3") { showBootstrap = true }
                        row("Link to my existing account", "link") { showPairing = true }
                    }
                }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            }.padding(22)
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .sheet(isPresented: $showPassword) { ChangePasswordView() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showNotifications) { NotificationsView() }
        .sheet(isPresented: $showProfile) { ProfilePreferencesView() }
        .sheet(isPresented: $showInvite) { NavigationStack { PeopleView() } }
        .sheet(isPresented: $showDevices) { DevicesView() }
        .sheet(isPresented: $showEnrollment) { EnrollmentView() }
        .sheet(isPresented: $showBootstrap) { BootstrapView() }
        .sheet(isPresented: $showPairing) { PairExistingDeviceView() }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }.padding(17)
        }.buttonStyle(.plain)
    }
}

private struct ChangePasswordView: View {
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SecureField("Current app password", text: $old).flField()
                SecureField("New app password · 12 characters minimum", text: $new).flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                PrimaryButton(title: "Change password") {
                    do { try vault.changeAppPassword(old: old, new: new); dismiss() }
                    catch { self.error = "Password change failed" }
                }
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("Change password")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onDisappear { old = ""; new = "" }
    }
}

private struct EnrollmentView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    @State private var code = ""
    @State private var scanInvitation = false
    @State private var name = ""
    @State private var username = ""
    @State private var status = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("Invitation code", text: $code).flField()
                Button("Scan invitation") { scanInvitation = true }
                    .sheet(isPresented: $scanInvitation) { PairingScanner(expected: .invitation) { code = $0 } }
                TextField("Name", text: $name).flField()
                TextField("Username", text: $username).flField()
                if !status.isEmpty { Text(status).foregroundStyle(Palette.muted) }
                PrimaryButton(title: "Request approval") {
                    Task {
                        do {
                            let admission = try await gateway.enroll(code: code, name: name, username: username)
                            try vault.setProfile(name: name, username: username,
                                                 userID: admission.user_id, deviceID: admission.device_id)
                            status = "Waiting for approval. Try People after your friend approves."
                        } catch { status = "Can't connect or invitation unavailable" }
                    }
                }
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("Use invitation")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onDisappear { code = ""; name = ""; username = "" }
    }
}

private struct BootstrapView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    @State private var token = ""
    @State private var name = ""
    @State private var username = ""
    @State private var status = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Use the one-time setup secret from the person deploying the service.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                SecureField("Setup secret", text: $token).flField()
                TextField("Name", text: $name).flField()
                TextField("Username", text: $username).flField()
                if !status.isEmpty { Text(status).foregroundStyle(Palette.muted) }
                PrimaryButton(title: "Set up first device") {
                    Task {
                        do {
                            let result = try await gateway.bootstrap(token: token, name: name, username: username)
                            try vault.setProfile(name: name, username: username,
                                                 userID: result.user_id, deviceID: result.device_id)
                            token = ""
                            dismiss()
                        } catch { status = "Can't connect or setup unavailable" }
                    }
                }
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("First device setup")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onDisappear { token = ""; name = ""; username = "" }
    }
}

private struct PairExistingDeviceView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    @State private var publicKey = ""
    @State private var deviceID = ""
    @State private var scanDeviceID = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("On your existing iPhone, open You → Authorized devices → Add device. Transfer this public pairing key through a trusted channel and compare it on both phones.")
                    Text(publicKey).font(.body.monospaced()).textSelection(.enabled)
                    PairingQRCode(value: publicKey, kind: .publicKey)
                    Text("Public pairing key. Your private key stays on this iPhone.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                    TextField("Device ID from your existing iPhone", text: $deviceID)
                        .textInputAutocapitalization(.never).flField()
                    Button("Scan device ID") { scanDeviceID = true }
                        .sheet(isPresented: $scanDeviceID) { PairingScanner(expected: .deviceID) { deviceID = $0 } }
                    Text("Approve the device on your existing iPhone before continuing. Old messages are not transferred.")
                        .font(.footnote)
                    if !status.isEmpty { Text(status).foregroundStyle(Palette.muted) }
                    PrimaryButton(title: "Finish linking") {
                        let generation = vault.chatGeneration
                        Task {
                            do {
                                try await gateway.login(deviceID: deviceID.trimmingCharacters(in: .whitespacesAndNewlines))
                                let profile = try await gateway.accountProfile()
                                guard vault.chatGeneration == generation else { return }
                                try vault.setProfile(name: profile.name, username: profile.username,
                                    userID: profile.user_id, deviceID: profile.device_id)
                                dismiss()
                            } catch { status = "Device not approved or can't connect" }
                        }
                    }
                }.padding(22)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("Link this iPhone")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
                .task { publicKey = (try? gateway.pairingPublicKey()) ?? "" }
        }.onDisappear { publicKey = ""; deviceID = "" }
    }
}

private struct ApproveNewDeviceView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    @State private var publicKey = ""
    @State private var pendingID = ""
    @State private var status = ""
    @State private var busy = false
    @State private var scanPublicKey = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter the public pairing key displayed by your new iPhone. Check the complete key on both screens before approving.")
                    TextField("Public pairing key", text: $publicKey)
                        .textInputAutocapitalization(.never).flField().disabled(!pendingID.isEmpty)
                    Button("Scan public pairing key") { scanPublicKey = true }.disabled(!pendingID.isEmpty)
                        .sheet(isPresented: $scanPublicKey) { PairingScanner(expected: .publicKey) { publicKey = $0 } }
                    if !pendingID.isEmpty {
                        Text("Device ID").font(.headline)
                        Text(pendingID).font(.body.monospaced()).textSelection(.enabled)
                        PairingQRCode(value: pendingID, kind: .deviceID)
                        Text("Enter this ID on the new iPhone. This approval expires after ten minutes. No message history or chat keys will be transferred.")
                            .font(.footnote)
                        PrimaryButton(title: "I compared the key — approve device") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    try await gateway.approveDevice(pendingID)
                                    status = "Approved. Finish linking on the new iPhone."
                                    pendingID = ""
                                    publicKey = ""
                                } catch { status = "Approval unavailable or expired" }
                            }
                        }.disabled(busy)
                    } else {
                        PrimaryButton(title: "Create approval request") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    try await gateway.login(deviceID: vault.deviceID)
                                    publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                    pendingID = try await gateway.requestDevice(publicKey: publicKey)
                                } catch { status = "Invalid pairing key or can't connect" }
                            }
                        }.disabled(busy)
                    }
                    if !status.isEmpty { Text(status).foregroundStyle(Palette.muted) }
                }.padding(22)
            }.background(Palette.background).foregroundStyle(Palette.text)
                .navigationTitle("Add device")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }.onDisappear { publicKey = ""; pendingID = "" }
    }
}

private struct DevicesView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @State private var devices: [DeviceInfo] = []
    @State private var error = ""
    @State private var showAddDevice = false
    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty { Text(error) }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.id == vault.deviceID ? "This iPhone" : "Device")
                            Text(device.state).font(.footnote).foregroundStyle(Palette.muted)
                            Text(device.id).font(.caption2.monospaced()).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if device.state == "active" {
                            Button("Revoke", role: .destructive) {
                                Task {
                                    do {
                                        try await gateway.revoke(device.id)
                                        if device.id == vault.deviceID { gateway.disconnect(); vault.lockApp() }
                                        else { devices = try await gateway.devices() }
                                    } catch { self.error = "Can't connect" }
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("Authorized devices")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add device") { showAddDevice = true }
                    }
                }
                .sheet(isPresented: $showAddDevice, onDismiss: {
                    Task { devices = (try? await gateway.devices()) ?? [] }
                }) { ApproveNewDeviceView() }
                .task {
                    do { devices = try await gateway.devices() }
                    catch { self.error = "Can't connect" }
                }
        }
        .onDisappear { devices.removeAll(keepingCapacity: false) }
    }
}

private struct PrivacyView: View {
    private let notes = [
        "The app password is required whenever you return. It is separate from your iPhone passcode.",
        "Each chat has a separate local password. Chats relock when you leave them.",
        "Messages stay hidden in lists and notifications. No notification reply actions are provided.",
        "Recording and mirroring hide the app when iOS reports capture. A screenshot can already exist when iOS tells the app about it.",
        "No export or attachment saving controls are provided. A recipient can still transcribe or photograph a screen.",
        "One-to-one messages use the pinned libsignal protocol after you compare and approve the other device's fingerprint. This build is not independently reviewed, and live two-device gateway delivery still needs signed-device testing.",
        "The service can see membership, devices, delivery timing, and ciphertext sizes. It cannot decrypt ciphertext submitted to its relay.",
        "Losing a password or device key can make local history unrecoverable. There is no recovery key held by the service."
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(notes, id: \.self) { note in
                        Text(note).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(22)
            }.navigationTitle("Privacy protections")
                .background(Palette.background).foregroundStyle(Palette.text)
        }
    }
}
