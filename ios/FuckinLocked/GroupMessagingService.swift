import Foundation
import LibSignalClient

struct GroupMember: Decodable, Identifiable {
    let device_id: String
    let user_id: String
    let name: String
    let state: String
    var id: String { device_id }
}

struct GroupInfo: Decodable {
    let room_id: String
    let owner_user_id: String
    let blocked: Bool
    let devices: [GroupMember]
}

// This value, including its random capability, is stored only in the parent
// group's chat-password ciphertext. Child vaults are internal Signal transports,
// never independently displayed/unlocked conversations.
struct GroupTransport: Codable {
    let directoryID: UUID
    let roomID: String
    let userID: String
    let deviceID: String
    let password: String
}

struct GroupPeerCheck: Identifiable {
    let id: String
    let name: String
    let ownFingerprint: String
    let peerFingerprint: String
    let verified: Bool
}

struct GroupDisplayedMessage: Identifiable {
    let senderDevice: String
    var message: StoredMessage
    var id: String { senderDevice + ":" + message.id.uuidString }
}

enum GroupMessagingError: Error { case closed, verificationRequired }

@MainActor final class GroupMessagingService: ObservableObject {
    @Published private(set) var peers: [GroupPeerCheck] = []
    @Published private(set) var messages: [GroupDisplayedMessage] = []
    @Published private(set) var working = false
    @Published private(set) var closed = false
    @Published private(set) var members: [GroupMember] = []
    @Published private(set) var ownerUserID = ""

    var ready: Bool { !closed && !peers.isEmpty && peers.allSatisfy(\.verified) }
    private let id: UUID
    private let vault: LocalVault
    private let gateway: Gateway
    private var observer: UUID?
    private struct Transport {
        let vault: LocalVault
        let messaging: MessagingService
        let chatID: UUID
    }
    private var transports: [String: Transport] = [:]

    init(id: UUID, vault: LocalVault, gateway: Gateway) {
        self.id = id
        self.vault = vault
        self.gateway = gateway
        observer = vault.observeChatLock { [weak self] in self?.lock() }
    }

    private func check(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard vault.isUnlocked, vault.unlockedChatID == id,
              vault.chatGeneration == generation else { throw MessagingError.unavailable }
    }

    private func room() throws -> String {
        let chat = try vault.chatMetadata(for: id)
        guard chat.isGroup, let room = chat.roomID else { throw MessagingError.localChatOnly }
        return room
    }

    private func openTransports() throws {
        for binding in try vault.groupBindings(for: id) ?? [] {
            if transports[binding.deviceID] != nil { continue }
            let directory = try vault.groupTransportDirectory(group: id, transport: binding.directoryID)
            let child = LocalVault(directory: directory)
            if child.isConfigured { try child.unlock(binding.password) }
            else { try child.createAppPassword(binding.password) }
            try child.setProfile(name: vault.profileName, username: vault.username,
                                 userID: vault.indexedUserID, deviceID: vault.deviceID)
            if child.chats.isEmpty {
                try child.createChat(title: "Group transport", isGroup: false, password: binding.password,
                    roomID: binding.roomID, remoteUserID: binding.userID, remoteDeviceID: binding.deviceID)
            }
            guard let chatID = child.chats.first?.id else { throw VaultError.corrupt }
            try child.unlockChat(chatID, password: binding.password)
            transports[binding.deviceID] = Transport(vault: child,
                messaging: MessagingService(vault: child, gateway: gateway), chatID: chatID)
        }
    }

    func synchronize() async throws {
        guard !working else { throw MessagingError.busy }
        working = true
        defer { rebuild(); working = false }
        let generation = vault.chatGeneration
        try check(generation)
        let groupID = try room()
        try openTransports() // cached history remains readable while offline
        try await gateway.login(deviceID: vault.deviceID)
        try check(generation)
        let info = try await gateway.groupInfo(groupID)
        try check(generation)
        guard info.room_id == groupID, !info.blocked,
              info.devices.count >= 3, info.devices.count <= 8,
              info.devices.allSatisfy({ $0.state == "active" }),
              info.devices.contains(where: { $0.device_id == vault.deviceID }) else {
            closed = true
            throw GroupMessagingError.closed
        }
        do { try vault.pinGroupRoster(info.devices.map(\.device_id), for: id) }
        catch { closed = true; throw error }
        members = info.devices
        ownerUserID = info.owner_user_id
        for peer in info.devices where peer.device_id != vault.deviceID {
            if try vault.groupBindings(for: id)?.contains(where: { $0.deviceID == peer.device_id }) != true {
                let pairRoom = try await gateway.groupLink(groupID, peerDevice: peer.device_id)
                try check(generation)
                var bindings = try vault.groupBindings(for: id) ?? []
                bindings.append(GroupTransport(directoryID: UUID(), roomID: pairRoom,
                    userID: peer.user_id, deviceID: peer.device_id,
                    password: UUID().uuidString + UUID().uuidString))
                // Persist the random capability before any child vault exists.
                try vault.saveGroupBindings(bindings, for: id)
            }
        }
        try openTransports()
        for device in transports.keys.sorted() {
            try check(generation)
            guard let transport = transports[device] else { continue }
            if (try? transport.messaging.isPeerVerified(for: transport.chatID)) != true {
                do { _ = try await transport.messaging.preparePeerVerification(for: transport.chatID) }
                catch ConnectionError.unavailable { continue } // other member must open their group
            } else {
                try await transport.messaging.receive(in: transport.chatID)
            }
        }
        try check(generation)
        rebuild()
        guard ready else { return }
        // The parent queue makes multi-recipient crash recovery atomic. Each
        // child also persists its own exact ciphertext/ratchet before uploading.
        let broadcasts = try vault.groupOutbox(for: id)
        for content in broadcasts {
            for device in transports.keys.sorted() {
                try check(generation)
                guard let transport = transports[device] else { continue }
                if !transport.vault.messageRecords.contains(where: { $0.id == content.id }) {
                    do { try await transport.messaging.sendGroupContent(content, in: transport.chatID) }
                    catch MessagingError.queued {} // already durable in this child
                }
            }
            try check(generation)
            try vault.finishGroupFanout(content.id, for: id)
        }
    }

    func verify(_ device: String) throws {
        guard vault.unlockedChatID == id, !closed, let transport = transports[device] else {
            throw MessagingError.unavailable
        }
        try transport.messaging.verifyPeer(for: transport.chatID)
        rebuild()
    }

    func send(_ text: String) async throws {
        try await send(MessageContent(id: UUID(), text: text.trimmingCharacters(in: .whitespacesAndNewlines), groupID: try room()))
    }

    func sendImage(_ bytes: Data) async throws {
        try await send(MessageContent(id: UUID(), text: "", image: bytes, groupID: try room()))
    }

    func react(_ value: String, to target: UUID) async throws {
        guard messages.contains(where: { $0.message.id == target }) else { throw MessagingError.invalidMessage }
        try await send(MessageContent(id: UUID(), text: "", reactionTarget: target, reaction: value, groupID: try room()))
    }

    private func send(_ content: MessageContent) async throws {
        guard !working else { throw MessagingError.busy }
        guard ready else { throw GroupMessagingError.verificationRequired }
        try content.validate()
        try vault.queueGroupContent(content, for: id)
        rebuild()
        do { try await synchronize() } catch { throw MessagingError.queued }
    }

    func removeMember(_ userID: String) async throws {
        let generation = vault.chatGeneration
        try check(generation)
        try await gateway.removeGroupMember(try room(), userID: userID)
        try check(generation)
        closed = true
    }

    private func rebuild() {
        guard vault.unlockedChatID == id else { lock(); return }
        peers = members.filter { $0.device_id != vault.deviceID }.map { member in
            let transport = transports[member.device_id]
            return GroupPeerCheck(id: member.device_id, name: member.name,
                ownFingerprint: transport.flatMap { try? $0.messaging.ownFingerprint(for: $0.chatID) } ?? "",
                peerFingerprint: transport.flatMap { try? $0.vault.pendingPeerBundle(for: $0.chatID)?.fingerprint } ?? "",
                verified: transport.flatMap { try? $0.messaging.isPeerVerified(for: $0.chatID) } ?? false)
        }
        let groupID = try? room()
        var byID: [String: GroupDisplayedMessage] = [:]
        var reactions: [StoredMessage] = []
        for transport in transports.values {
            for message in transport.vault.messageRecords where message.groupID == groupID {
                if message.reactionTarget != nil { reactions.append(message); continue }
                let sender = message.senderDeviceID ?? ""
                let key = sender + ":" + message.id.uuidString
                if var existing = byID[key], message.isOutgoing {
                    if message.delivery == .sending || existing.message.delivery == .sending {
                        existing.message.delivery = .sending
                    } else if message.delivery != .delivered || existing.message.delivery != .delivered {
                        existing.message.delivery = .accepted
                    }
                    byID[key] = existing
                } else { byID[key] = GroupDisplayedMessage(senderDevice: sender, message: message) }
            }
        }
        for content in (try? vault.groupOutbox(for: id)) ?? [] where content.reactionTarget == nil {
            let key = vault.deviceID + ":" + content.id.uuidString
            if byID[key] == nil {
                byID[key] = GroupDisplayedMessage(senderDevice: vault.deviceID,
                    message: StoredMessage(id: content.id, body: content.text, sentAt: Date(),
                        isOutgoing: true, delivery: .sending, envelopeID: nil, ciphertext: nil,
                        image: content.image, groupID: content.groupID, senderDeviceID: vault.deviceID))
            } else { byID[key]?.message.delivery = .sending }
        }
        // Start from a clean aggregate: child one-to-one records can contain
        // their own reaction maps, but group reactions are merged once below.
        for key in byID.keys { byID[key]?.message.reactions = nil }
        for event in reactions.sorted(by: { $0.sentAt < $1.sentAt }) {
            guard let target = event.reactionTarget, let reaction = event.reaction else { continue }
            for key in Array(byID.keys) {
                guard var item = byID[key], item.message.id == target else { continue }
                var merged = item.message.reactions ?? [:]
                merged[event.senderDeviceID ?? "peer"] = reaction
                item.message.reactions = merged
                byID[key] = item
            }
        }
        messages = byID.values.sorted { $0.message.sentAt < $1.message.sentAt }
    }

    func lock() {
        for transport in transports.values { transport.vault.lockApp(); transport.messaging.clearTransientState() }
        transports.removeAll(keepingCapacity: false)
        messages.removeAll(keepingCapacity: false)
        peers.removeAll(keepingCapacity: false)
        members.removeAll(keepingCapacity: false)
        ownerUserID = ""
    }

    func close() {
        if let observer { vault.removeChatLockObserver(observer); self.observer = nil }
        lock()
    }
}
