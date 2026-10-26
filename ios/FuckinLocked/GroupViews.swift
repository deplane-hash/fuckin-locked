import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct GroupComposeView: View {
    @EnvironmentObject var vault: LocalVault
    @EnvironmentObject var gateway: Gateway
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var rooms: [RoomInfo] = []
    @State private var selected: Set<String> = []
    @State private var devices: [String: [RoomDevice]] = [:]
    @State private var chosenDevices: [String: String] = [:]
    @State private var existing = ""
    @State private var title = ""
    @State private var password = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Each member uses their own local group password. Every selected device must be verified before sending.")
                    Picker("Conversation", selection: $existing) {
                        Text("New private group").tag("")
                        ForEach(rooms.filter { $0.is_group == true }) { room in
                            Text(room.members.map(\.name).joined(separator: ", ")).tag(room.id)
                        }
                    }
                    TextField("Local group name", text: $title)
                    SecureField("Separate group password · 12 characters minimum", text: $password)
                }
                if existing.isEmpty {
                    Section("Choose 2–7 friends") {
                        ForEach(people.filter { $0.id != vault.indexedUserID }) { person in
                            Toggle(person.name, isOn: Binding(get: { selected.contains(person.id) }, set: {
                                if $0 { selected.insert(person.id) } else { selected.remove(person.id) }
                            }))
                            if selected.contains(person.id) {
                                Picker("\(person.name)'s device", selection: Binding(
                                    get: { chosenDevices[person.id] ?? "" },
                                    set: { chosenDevices[person.id] = $0 })) {
                                    Text("Select device").tag("")
                                    ForEach(devices[person.id] ?? [], id: \.id) { device in
                                        Text(device.id).tag(device.id)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("The roster is fixed. Removing a member or revoking a selected device closes this group to new traffic. Start a new group and compare fingerprints to continue with a changed roster; old history is not transferred.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                    if !status.isEmpty { Text(status).foregroundStyle(.red) }
                    Button(existing.isEmpty ? "Create private group" : "Add private group") {
                        guard password.count >= 12, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            status = "Enter a name and a password of at least 12 characters"; return
                        }
                        let generation = vault.chatGeneration
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let room: String
                                if existing.isEmpty {
                                    let targets = selected.sorted().compactMap { chosenDevices[$0] }.filter { !$0.isEmpty }
                                    guard targets.count == selected.count, (2...7).contains(targets.count) else {
                                        status = "Choose one device for each of 2–7 friends"; return
                                    }
                                    room = try await gateway.createGroup(peerDevices: targets)
                                } else { room = existing }
                                guard vault.chatGeneration == generation else { return }
                                try vault.createChat(title: title, isGroup: true, password: password,
                                    roomID: room, remoteUserID: nil, remoteDeviceID: nil)
                                dismiss()
                            } catch { status = "Can't connect or group already added" }
                        }
                    }.disabled(busy || vault.deviceID.isEmpty)
                }
            }.navigationTitle("Private group")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
                .task {
                    guard !vault.deviceID.isEmpty else { status = "Finish account setup first"; return }
                    do {
                        try await gateway.login(deviceID: vault.deviceID)
                        people = try await gateway.people()
                        rooms = try await gateway.rooms()
                    } catch { status = "Can't connect" }
                }
                .task(id: selected.sorted().joined(separator: ":")) {
                    for userID in selected where devices[userID] == nil {
                        do {
                            let result = try await gateway.memberDevices(userID)
                            try Task.checkCancellation()
                            devices[userID] = result
                            if result.count == 1 { chosenDevices[userID] = result[0].id }
                        } catch { return }
                    }
                }
        }.tint(Palette.lime)
            .onDisappear { password = ""; selected = []; devices = [:]; chosenDevices = [:] }
    }
}

struct GroupConversationView: View {
    let id: UUID
    let title: String
    @ObservedObject private var vault: LocalVault
    @StateObject private var group: GroupMessagingService
    @State private var draft = ""
    @State private var status = ""
    @State private var drawer = false
    @State private var changePassword = false
    @State private var photo: PhotosPickerItem?
    @State private var viewedImage: Data?
    @State private var viewedFile: PrivateAttachment?
    @State private var filePicker = false
    @State private var fileGeneration: UInt64 = 0
    @State private var removal: GroupMember?

    init(id: UUID, title: String, vault: LocalVault, gateway: Gateway) {
        self.id = id; self.title = title
        _vault = ObservedObject(wrappedValue: vault)
        _group = StateObject(wrappedValue: GroupMessagingService(id: id, vault: vault, gateway: gateway))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { changePassword = true } label: { Image(systemName: "key") }
                    .accessibilityLabel("Change group password")
                Button("Lock chat") { vault.lockChat() }
            }.padding(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(group.peers.filter { !$0.verified }) { peer in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Compare with \(peer.name)").font(.headline)
                            Text("Your fingerprint for this member").font(.caption)
                            Text(peer.ownFingerprint).font(.caption2.monospaced())
                            Text("Their fingerprint").font(.caption)
                            Text(peer.peerFingerprint.isEmpty ? "Waiting for their device to open this group" : peer.peerFingerprint)
                                .font(.caption2.monospaced())
                            Button("I compared both fingerprints") {
                                do { try group.verify(peer.id) } catch { status = "Verification failed" }
                            }.disabled(peer.peerFingerprint.isEmpty || group.closed)
                        }.padding().background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    ForEach(group.messages) { item in
                        GroupBubble(item: item, sender: group.members.first(where: { $0.id == item.senderDevice })?.name ?? "Member",
                            ready: group.ready && !group.working,
                            viewImage: { viewedImage = $0 }, viewFile: { viewedFile = $0 }, react: { reaction in
                                Task {
                                    do { try await group.react(reaction, to: item.message.id) }
                                    catch { status = "Reaction saved for retry or unavailable" }
                                }
                            })
                    }
                }.padding(.horizontal)
            }
            if group.closed { Text("This roster changed. Create a new group to continue securely.").font(.footnote) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(Palette.muted) }
            HStack(spacing: 12) {
                Button { drawer.toggle() } label: { Image(systemName: "face.smiling") }
                    .accessibilityLabel("Stickers and emoji")
                PrivateMessageField(text: $draft, isEnabled: group.ready).frame(minHeight: 44)
                Button {
                    let text = draft
                    let generation = vault.chatGeneration
                    draft = ""
                    Task {
                        do { try await group.send(text) }
                        catch MessagingError.queued { status = "Saved. Waiting for a connection." }
                        catch {
                            guard vault.chatGeneration == generation else { return }
                            draft = text; status = "Can't send this message"
                        }
                    }
                } label: { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(!group.ready || group.working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send group message")
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Image(systemName: "paperclip").frame(minWidth: 44, minHeight: 44)
                }.disabled(!group.ready || group.working).accessibilityLabel("Attach image")
                Button {
                    fileGeneration = vault.chatGeneration; filePicker = true
                } label: { Image(systemName: "doc.badge.plus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(!group.ready || group.working).accessibilityLabel("Attach file or short media clip")
            }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 24)).padding(.horizontal)
            if drawer {
                StickerDrawer(id: id, insert: { draft += $0 }, sendSticker: { sticker in
                    Task {
                        do { try await group.sendImage(sticker.imageData()) }
                        catch { status = "Sticker saved for retry or unavailable" }
                    }
                }, close: { drawer = false })
            }
            if group.ownerUserID == vault.indexedUserID && !group.closed {
                Menu("Group members") {
                    ForEach(group.members.filter { $0.user_id != vault.indexedUserID }) { member in
                        Button("Remove \(member.name)", role: .destructive) { removal = member }
                    }
                }
            }
        }.foregroundStyle(Palette.text).background(Palette.background).tint(Palette.lime)
            .overlay {
                if let viewedImage {
                    VStack {
                        Button("Close image") { self.viewedImage = nil }.padding()
                        Spacer()
                        PrivateMediaImage(data: viewedImage).accessibilityLabel("Group message image")
                        Spacer()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
                }
            }
            .sheet(isPresented: $changePassword) { ChangeChatPasswordView(id: id) }
            .sheet(item: $viewedFile) { file in PrivateAttachmentView(attachment: file) { viewedFile = nil } }
            .sheet(isPresented: $filePicker) {
                StickerPackPicker(allowedTypes: [.pdf, .plainText, .wav, .mpeg4Audio, .mp3, .mpeg4Movie, .quickTimeMovie]) { result in
                    filePicker = false
                    guard vault.unlockedChatID == id, vault.chatGeneration == fileGeneration else { return }
                    do {
                        let file = try PrivateAttachment.read(result.get())
                        Task {
                            do { try await group.sendFile(file) }
                            catch { status = "File saved for retry or unavailable" }
                        }
                    } catch { status = "Choose a supported file up to 512 KB: TXT, PDF, WAV, M4A, MP3, MP4 or MOV." }
                }
            }
            .confirmationDialog("Removing this member closes the group to new messages. Cached history remains locked by its password.",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                if let removal {
                    Button("Remove member and close group", role: .destructive) {
                        Task {
                            do { try await group.removeMember(removal.user_id) }
                            catch { status = "Can't change group membership" }
                        }
                    }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                let generation = vault.chatGeneration
                Task {
                    defer { photo = nil }
                    do {
                        guard let bytes = try await item.loadTransferable(type: Data.self),
                              vault.chatGeneration == generation else { return }
                        try await group.sendImage(PrivateImage.importMedia(bytes))
                    } catch { status = "Image saved for retry or unavailable" }
                }
            }
            .task {
                while !Task.isCancelled && vault.unlockedChatID == id {
                    do { try await group.synchronize(); status = "" }
                    catch GroupMessagingError.closed { break }
                    catch { status = "Can't connect. Retrying while this group is open." }
                    do { try await Task.sleep(for: .seconds(3)) } catch { break }
                }
            }
            .onDisappear {
                draft = ""; viewedImage = nil; viewedFile = nil; photo = nil; drawer = false
                group.close(); vault.lockChat()
            }
    }
}

private struct GroupBubble: View {
    @EnvironmentObject private var vault: LocalVault
    let item: GroupDisplayedMessage
    let sender: String
    let ready: Bool
    let viewImage: (Data) -> Void
    let viewFile: (PrivateAttachment) -> Void
    let react: (String) -> Void
    var body: some View {
        HStack {
            if item.message.isOutgoing { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 5) {
                if !item.message.isOutgoing { Text(sender).font(.caption).foregroundStyle(Palette.muted) }
                if let bytes = item.message.image {
                    Button { viewImage(bytes) } label: {
                        PrivateMediaImage(data: bytes).frame(width: 220, height: 220)
                    }.accessibilityLabel("View image")
                }
                if let file = item.message.file {
                    Button { viewFile(file) } label: { Label(file.name, systemImage: "doc").padding(10) }
                        .accessibilityLabel("Open attachment \(file.name)")
                }
                if !item.message.body.isEmpty {
                    Text(item.message.body).font(vault.preferences.largerMessages ? .title3 : .body).padding(12)
                        .foregroundStyle(item.message.isOutgoing ? Palette.background : Palette.text)
                        .background(item.message.isOutgoing ? Palette.lime : Palette.surface,
                                    in: RoundedRectangle(cornerRadius: 16))
                }
                if let reactions = item.message.reactions {
                    Text(reactions.sorted { $0.key < $1.key }.map(\.value).joined(separator: " "))
                }
                HStack {
                    Text(item.message.sentAt, style: .time)
                    if item.message.isOutgoing {
                        Text(item.message.delivery == .delivered ? "Delivered to all" :
                             item.message.delivery == .accepted ? "Sent to all" : "Waiting to send")
                    }
                }.font(.caption2).foregroundStyle(Palette.muted)
                Menu {
                    ForEach(MessageContent.reactions, id: \.self) { value in Button(value) { react(value) } }
                } label: { Image(systemName: "face.smiling").frame(minWidth: 44, minHeight: 44) }
                    .disabled(!ready).accessibilityLabel("React to group message")
            }
            if !item.message.isOutgoing { Spacer(minLength: 36) }
        }
    }
}
