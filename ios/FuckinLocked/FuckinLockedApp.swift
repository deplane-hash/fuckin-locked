import SwiftUI
import UIKit

private enum Palette {
    static let background = Color(red: 16/255, green: 18/255, blue: 18/255)
    static let surface = Color(red: 31/255, green: 34/255, blue: 33/255)
    static let lime = Color(red: 182/255, green: 246/255, blue: 83/255)
    static let text = Color(red: 247/255, green: 246/255, blue: 240/255)
    static let muted = Color(red: 174/255, green: 179/255, blue: 171/255)
}

@main struct FuckinLockedApp: App {
    @StateObject private var vault: LocalVault
    @StateObject private var gateway: Gateway
    @StateObject private var messaging: MessagingService
    @Environment(\.scenePhase) private var phase
    @Environment(\.isSceneCaptured) private var captured
    @State private var forceCover = false

    init() {
        let vault = LocalVault()
        let gateway = Gateway()
        _vault = StateObject(wrappedValue: vault)
        _gateway = StateObject(wrappedValue: gateway)
        _messaging = StateObject(wrappedValue: MessagingService(vault: vault, gateway: gateway))
    }

    var body: some Scene {
        WindowGroup {
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
            .environmentObject(vault)
            .environmentObject(gateway)
            .environmentObject(messaging)
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
            .onChange(of: captured) { _, isCaptured in
                if isCaptured { gateway.disconnect(); vault.lockApp() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                vault.lockChat()
            }
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

private struct PrimaryButton: View {
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
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock").font(.system(size: 36, weight: .light)).foregroundStyle(Palette.lime)
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.bold()).foregroundStyle(Palette.text)
            Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            content
            Spacer()
        }
        .padding(26)
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
                    .textContentType(.newPassword).textInputAutocapitalization(.never)
                    .flField()
                SecureField("Repeat password", text: $repeatPassword)
                    .textContentType(.newPassword).flField()
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
    var body: some View {
        PasswordLayout(title: "fuckin locked", subtitle: "This app locks whenever you leave it.", content:
            VStack(spacing: 14) {
                SecureField("App password", text: $password)
                    .textContentType(.password).flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
                PrimaryButton(title: "Unlock") {
                    do { try vault.unlock(password); password = ""; error = "" }
                    catch VaultError.delayed(let seconds) { error = "Try again in \(seconds) seconds" }
                    catch { self.error = "Password incorrect" }
                }
            })
        .onDisappear { password = "" }
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
    case chats = "Chats", people = "People", you = "You"
    var symbol: String {
        switch self { case .chats: "bubble.left.and.bubble.right"; case .people: "person.2"; case .you: "person.crop.circle" }
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

private struct ChatsView: View {
    @EnvironmentObject var vault: LocalVault
    @State private var search = ""
    @State private var groupsOnly = false
    @State private var compose = false
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
                    Text("No chats yet").foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 180)
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
                            Image(systemName: "lock.fill").foregroundStyle(Palette.muted).font(.caption)
                        }.padding(.vertical, 8)
                    }
                    Divider().overlay(Palette.surface)
                }
            }.padding(22)
        }
        .navigationDestination(for: UUID.self) { id in ChatGateView(id: id) }
        .sheet(isPresented: $compose) { ComposeView() }
        .background(Palette.background)
        .foregroundStyle(Palette.text)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { search = "" }
    }

    private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 17).padding(.vertical, 9) }
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .background(selected ? Palette.lime : Palette.surface, in: Capsule())
    }
}

private struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @State private var title = ""
    @State private var password = ""
    @State private var group = false
    @State private var error = ""
    @State private var people: [Person] = []
    @State private var selectedPersonID = ""

    private var availablePeople: [Person] {
        people.filter { $0.id != vault.indexedUserID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(selectedPersonID.isEmpty ? "Local draft chat" : "Encrypted one-to-one")
                    .font(.headline)
                Text(selectedPersonID.isEmpty
                     ? "A local draft is stored only on this device."
                     : "Messages use an end-to-end encrypted session after device verification.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                if !availablePeople.isEmpty {
                    Picker("Friend", selection: $selectedPersonID) {
                        Text("Local draft").tag("")
                        ForEach(availablePeople) { person in
                            Text("\(person.name) · @\(person.username)").tag(person.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                }
                TextField("Name", text: $title).flField()
                if selectedPersonID.isEmpty {
                    Toggle("Group", isOn: $group).tint(Palette.lime)
                }
                SecureField("Separate chat password", text: $password).flField()
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                PrimaryButton(title: selectedPersonID.isEmpty ? "Create locked draft" : "Create encrypted chat") {
                    Task {
                        do {
                            if selectedPersonID.isEmpty {
                                try vault.createChat(title: title, isGroup: group, password: password)
                            } else {
                                try await gateway.login(deviceID: vault.deviceID)
                                let room = try await gateway.createOneToOneRoom(with: selectedPersonID)
                                let devices = try await gateway.roomDevices(room)
                                guard let peer = devices.first(where: { $0.user_id == selectedPersonID }) else {
                                    throw ConnectionError.invalidResponse
                                }
                                let person = availablePeople.first(where: { $0.id == selectedPersonID })
                                try vault.createChat(title: person?.name ?? title, isGroup: false,
                                                     password: password, roomID: room,
                                                     remoteUserID: selectedPersonID,
                                                     remoteDeviceID: peer.id)
                            }
                            dismiss()
                        } catch {
                            self.error = selectedPersonID.isEmpty
                                ? "Enter a name and a password of at least 12 characters"
                                : "Can't connect or create this chat"
                        }
                    }
                }
                Spacer()
            }.padding(22).background(Palette.background).foregroundStyle(Palette.text)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .task {
            guard !vault.deviceID.isEmpty else { return }
            try? await gateway.login(deviceID: vault.deviceID)
            people = (try? await gateway.people()) ?? []
        }
        .onDisappear { title = ""; password = "" }
    }
}

private struct ChatGateView: View {
    @EnvironmentObject var vault: LocalVault
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var password = ""
    @State private var error = ""
    var title: String { vault.chats.first(where: { $0.id == id })?.title ?? "Chat" }
    var body: some View {
        Group {
            if vault.unlockedChatID == id {
                ConversationView(id: id, title: title)
            } else {
                PasswordLayout(title: title, subtitle: "This chat has a separate password.", content:
                    VStack(spacing: 14) {
                        SecureField("Chat password", text: $password).flField()
                        if !error.isEmpty { Text(error).foregroundStyle(.red) }
                        PrimaryButton(title: "Unlock chat") {
                            do { try vault.unlockChat(id, password: password); password = "" }
                            catch VaultError.delayed(let seconds) { error = "Try again in \(seconds) seconds" }
                            catch { self.error = "Password incorrect" }
                        }
                    })
            }
        }
        .background(Palette.background)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Lock chat") { vault.lockChat(); dismiss() }
        }}
        .onDisappear { password = ""; vault.lockChat() }
    }
}

private struct ConversationView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var messaging: MessagingService
    let id: UUID
    let title: String
    @State private var draft = ""
    @State private var drawer = false
    @State private var showChangePassword = false
    @State private var fingerprint = ""
    @State private var verified = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { showChangePassword = true } label: { Image(systemName: "key") }
                    .accessibilityLabel("Change chat password")
                Button("Lock chat") { draft = ""; vault.lockChat() }
                    .foregroundStyle(Palette.lime)
            }.padding(.horizontal)
            if !fingerprint.isEmpty && !verified {
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
                    ForEach(vault.messageRecords) { message in
                        HStack {
                            if message.isOutgoing { Spacer(minLength: 36) }
                            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                                Text(message.body).padding(11)
                                    .foregroundStyle(message.isOutgoing ? Palette.background : Palette.text)
                                    .background(message.isOutgoing ? Palette.lime : Palette.surface,
                                                in: RoundedRectangle(cornerRadius: 16))
                                if message.isOutgoing {
                                    Text(message.delivery == .delivered ? "Delivered" : "Sending")
                                        .font(.caption2).foregroundStyle(Palette.muted)
                                }
                            }
                            if !message.isOutgoing { Spacer(minLength: 36) }
                        }
                    }
                }.padding(.horizontal)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(Palette.muted) }
            HStack(spacing: 12) {
                Button { drawer.toggle() } label: { Image(systemName: "face.smiling") }
                    .accessibilityLabel("Stickers and emoji")
                TextField("Message", text: $draft)
                    .disabled(!verified)
                Button {
                    let outgoing = draft
                    draft = ""
                    Task {
                        do { try await messaging.send(outgoing, in: id) }
                        catch MessagingError.identityVerificationRequired(let value) {
                            fingerprint = value; verified = false; status = "Verify the device first"; draft = outgoing
                        }
                        catch { status = "Can't send"; draft = outgoing }
                    }
                } label: { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(!verified || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
                Button {} label: { Image(systemName: "paperclip") }
                    .disabled(true).accessibilityLabel("Attachments unavailable")
            }.padding(14).background(Palette.surface, in: Capsule()).padding(.horizontal)
            if drawer { StickerDrawer() }
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .sheet(isPresented: $showChangePassword) { ChangeChatPasswordView(id: id) }
        .task {
            do {
                fingerprint = try await messaging.preparePeerVerification(for: id)
                verified = try messaging.isPeerVerified(for: id)
                if verified { try? await messaging.receive(in: id) }
            } catch MessagingError.localChatOnly {
                status = "Local draft — delivery is not configured"
            } catch MessagingError.identityVerificationRequired(let value) {
                fingerprint = value
            } catch { status = "Can't connect" }
        }
        .onDisappear { draft = ""; drawer = false; vault.lockChat() }
    }
}

private struct ChangeChatPasswordView: View {
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

private struct StickerDrawer: View {
    @State private var search = ""
    private let items = ["🙂", "😄", "💚", "✨", "🔥", "🙌", "🎉", "🌙", "🐈", "🦊", "🪐", "🍋"]
    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Palette.muted).frame(width: 36, height: 4)
            Text("Emoji").font(.headline)
            TextField("Search locally", text: $search).flField()
            if search.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(items, id: \.self) { item in Text(item).font(.largeTitle).frame(minHeight: 48) }
                }
            }
        }.padding().background(Palette.surface, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
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
                    Text("Give this code to your friend privately. It expires and needs approval.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                PrimaryButton(title: "Invite a friend") {
                    Task { do { invitation = try await gateway.invite() }
                        catch { self.error = "Can't connect" } }
                }
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
            do {
                try await gateway.login(deviceID: vault.deviceID)
                people = try await gateway.people()
                admissions = try await gateway.pendingAdmissions()
            }
            catch { self.error = "Can't connect" }
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
    @State private var showDevices = false
    @State private var showEnrollment = false
    @State private var showBootstrap = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("You").font(.largeTitle.bold())
                HStack(spacing: 14) {
                    Text(String(vault.profileName.prefix(1))).font(.title)
                        .frame(width: 58, height: 58).background(Palette.surface, in: Circle())
                    VStack(alignment: .leading) {
                        Text(vault.profileName).font(.headline)
                        Text(vault.username.isEmpty ? "Not enrolled" : "@\(vault.username)")
                            .foregroundStyle(Palette.muted)
                    }
                }
                VStack(spacing: 0) {
                    row("Change app password", "key") { showPassword = true }
                    row("Authorized devices", "iphone") { showDevices = true }
                    row("Privacy protections", "hand.raised") { showPrivacy = true }
                    if vault.deviceID.isEmpty {
                        row("Use invitation", "envelope") { showEnrollment = true }
                        row("First device setup", "iphone.gen3") { showBootstrap = true }
                    }
                }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            }.padding(22)
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .sheet(isPresented: $showPassword) { ChangePasswordView() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showDevices) { DevicesView() }
        .sheet(isPresented: $showEnrollment) { EnrollmentView() }
        .sheet(isPresented: $showBootstrap) { BootstrapView() }
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
    @State private var name = ""
    @State private var username = ""
    @State private var status = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("Invitation code", text: $code).flField()
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

private struct DevicesView: View {
    @EnvironmentObject var gateway: Gateway
    @EnvironmentObject var vault: LocalVault
    @State private var devices: [DeviceInfo] = []
    @State private var error = ""
    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty { Text(error) }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.id == vault.deviceID ? "This iPhone" : "Device")
                            Text(device.state).font(.footnote).foregroundStyle(Palette.muted)
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
        "For now, sending messages is unavailable. End-to-end encrypted sessions have not been integrated or verified.",
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
