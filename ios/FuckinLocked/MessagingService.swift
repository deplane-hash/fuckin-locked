import Foundation
import LibSignalClient
import CryptoKit

enum MessagingError: Error {
    case unavailable
    case localChatOnly
    case identityVerificationRequired(String)
    case invalidMessage
    case unsupportedGroup
    case unexpectedSender
    case busy
}

@MainActor final class MessagingService: ObservableObject {
    @Published private(set) var pendingFingerprints: [UUID: String] = [:]
    @Published private(set) var working = false

    private let vault: LocalVault
    private let gateway: Gateway

    private func check(_ id: UUID, generation: UInt64) throws {
        try Task.checkCancellation()
        guard vault.isUnlocked, vault.unlockedChatID == id,
              vault.chatGeneration == generation else { throw MessagingError.unavailable }
    }

    func ownFingerprint(for id: UUID) throws -> String {
        guard let state = try vault.signalState(for: id) else { throw MessagingError.unavailable }
        let store = VaultSignalStore(state: state)
        let bytes = try store.identityKeyPair(context: NullContext()).identityKey.serialize()
        return SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    init(vault: LocalVault, gateway: Gateway) {
        self.vault = vault
        self.gateway = gateway
    }

    private func metadata(for id: UUID) throws -> StoredChat {
        let chat = try vault.chatMetadata(for: id)
        guard !chat.isGroup, let roomID = chat.roomID,
              let remoteUserID = chat.remoteUserID,
              let remoteDeviceID = chat.remoteDeviceID,
              !roomID.isEmpty, !remoteUserID.isEmpty, !remoteDeviceID.isEmpty else {
            throw MessagingError.localChatOnly
        }
        return chat
    }

    private func login() async throws {
        guard !vault.deviceID.isEmpty else { throw MessagingError.unavailable }
        try await gateway.login(deviceID: vault.deviceID)
    }

    private func localAddress() throws -> ProtocolAddress {
        guard !vault.indexedUserID.isEmpty else { throw MessagingError.unavailable }
        return try ProtocolAddress(name: vault.indexedUserID, deviceId: 1)
    }

    private func addresses(for chat: StoredChat, bundle: RelayPrekeyBundle) throws
        -> (local: ProtocolAddress, remote: ProtocolAddress) {
        guard let remoteUserID = chat.remoteUserID else { throw MessagingError.localChatOnly }
        let local = try localAddress()
        let remote = try ProtocolAddress(name: remoteUserID, deviceId: bundle.device_number)
        return (local, remote)
    }

    private func ensureLocalPrekeys(for id: UUID, roomID: String) async throws {
        var state = try vault.signalState(for: id) ?? SignalState.new()
        let store = VaultSignalStore(state: state)
        let bundle: SignalPublicBundle
        if let current = try? store.currentPublicBundle() {
            bundle = current
        } else {
            bundle = try store.generatePublicBundle()
            state = store.state
            try vault.saveSignalState(state, for: id)
        }
        try await gateway.publishPrekeys(bundle, roomID: roomID)
    }

    private func peerBundle(for id: UUID, chat: StoredChat, generation: UInt64) async throws -> RelayPrekeyBundle {
        if let cached = try vault.pendingPeerBundle(for: id) { return cached }
        guard let roomID = chat.roomID, let deviceID = chat.remoteDeviceID else {
            throw MessagingError.localChatOnly
        }
        let bundle = try await gateway.takePrekeys(roomID: roomID, deviceID: deviceID)
        try check(id, generation: generation)
        guard bundle.device_id == deviceID, bundle.device_number == 1 else {
            throw MessagingError.unexpectedSender
        }
        try vault.savePendingPeerBundle(bundle, for: id)
        return bundle
    }

    func preparePeerVerification(for id: UUID) async throws -> String {
        guard !working else { throw MessagingError.busy }
        working = true
        defer { working = false }
        return try await prepare(id, generation: vault.chatGeneration)
    }

    private func prepare(_ id: UUID, generation: UInt64) async throws -> String {
        try check(id, generation: generation)
        let chat = try metadata(for: id)
        try await login()
        try check(id, generation: generation)
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        try check(id, generation: generation)
        let bundle = try await peerBundle(for: id, chat: chat, generation: generation)
        let fingerprint = bundle.fingerprint
        pendingFingerprints[id] = fingerprint
        return fingerprint
    }

    func verifyPeer(for id: UUID) throws {
        let chat = try metadata(for: id)
        guard let bundle = try vault.pendingPeerBundle(for: id),
              let remoteUserID = chat.remoteUserID else {
            throw MessagingError.unavailable
        }
        var state = try vault.signalState(for: id) ?? SignalState.new()
        let store = VaultSignalStore(state: state)
        let address = try ProtocolAddress(name: remoteUserID, deviceId: bundle.device_number)
        try store.approveIdentity(IdentityKey(bytes: bundle.identity_key), for: address)
        state = store.state
        try vault.saveSignalState(state, for: id)
        pendingFingerprints[id] = nil
    }

    func isPeerVerified(for id: UUID) throws -> Bool {
        let chat = try metadata(for: id)
        guard let bundle = try vault.pendingPeerBundle(for: id),
              let remoteUserID = chat.remoteUserID,
              let state = try vault.signalState(for: id) else { return false }
        let key = "\(bundle.device_number):\(remoteUserID)"
        return state.trustedIdentities[key] == bundle.identity_key
    }

    func send(_ text: String, in id: UUID) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await sendContent(MessageContent(id: UUID(), text: body), in: id)
    }

    func sendImage(_ image: Data, in id: UUID) async throws {
        try await sendContent(MessageContent(id: UUID(), text: "", image: image), in: id)
    }

    func react(_ reaction: String, to target: UUID, in id: UUID) async throws {
        guard vault.messageRecords.contains(where: { $0.id == target && $0.reactionTarget == nil }) else {
            throw MessagingError.invalidMessage
        }
        try await sendContent(MessageContent(id: UUID(), text: "", reactionTarget: target,
                                              reaction: reaction), in: id)
    }

    private func sendContent(_ content: MessageContent, in id: UUID) async throws {
        try content.validate()
        guard !working else { throw MessagingError.busy }
        working = true
        defer { working = false }
        let generation = vault.chatGeneration
        try check(id, generation: generation)
        let chat = try metadata(for: id)
        try await login()
        try check(id, generation: generation)
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        try check(id, generation: generation)
        let bundle = try await peerBundle(for: id, chat: chat, generation: generation)
        guard try isPeerVerified(for: id) else {
            throw MessagingError.identityVerificationRequired(bundle.fingerprint)
        }
        guard chat.remoteDeviceID != nil else { throw MessagingError.localChatOnly }
        var state = try vault.signalState(for: id) ?? SignalState.new()
        let store = VaultSignalStore(state: state)
        let addresses = try addresses(for: chat, bundle: bundle)
        if try store.loadSession(for: addresses.remote, context: NullContext()) == nil {
            try processPreKeyBundle(try bundle.protocolBundle(), for: addresses.remote,
                                    ourAddress: addresses.local, sessionStore: store,
                                    identityStore: store, context: NullContext())
        }
        let ciphertext = try signalEncrypt(message: JSONEncoder().encode(content), for: addresses.remote,
                                           localAddress: addresses.local, sessionStore: store,
                                           identityStore: store, context: NullContext())
        let wire = ciphertext.serialize()
        let message = StoredMessage(id: content.id, body: content.text, sentAt: Date(), isOutgoing: true,
                                    delivery: .sending, envelopeID: nil, ciphertext: wire,
                                    image: content.image, reactionTarget: content.reactionTarget,
                                    reaction: content.reaction)
        state = store.state
        try vault.commitChat(state: state, message: message, for: id)
        // Persist the exact wire bytes together with the advanced ratchet before
        // upload. Retries must reuse both these bytes and this stable ID.
        try await flushOutbox(in: id, chat: chat, generation: generation)
    }

    func receive(in id: UUID) async throws {
        guard !working else { throw MessagingError.busy }
        working = true
        defer { working = false }
        let generation = vault.chatGeneration
        try check(id, generation: generation)
        let chat = try metadata(for: id)
        try await login()
        try check(id, generation: generation)
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        try check(id, generation: generation)
        guard try isPeerVerified(for: id) else {
            let fingerprint = try await prepare(id, generation: generation)
            throw MessagingError.identityVerificationRequired(fingerprint)
        }
        try await flushOutbox(in: id, chat: chat, generation: generation)
        let envelopes = try await gateway.pendingEnvelopes(roomID: chat.roomID!)
        try check(id, generation: generation)
        for envelope in envelopes {
            try check(id, generation: generation)
            guard envelope.room_id == chat.roomID, envelope.kind == "message",
                  envelope.sender_device == chat.remoteDeviceID,
                  envelope.sender_user_id == chat.remoteUserID else {
                // Do not feed a ciphertext from an unbound device into this chat's
                // Signal address. A new device needs a separately approved chat
                // binding rather than silently sharing this session.
                throw MessagingError.unexpectedSender
            }
            if try vault.hasProcessedEnvelope(envelope.id, for: id) {
                try await gateway.acknowledgeEnvelope(envelope.id)
                continue
            }
            var state = try vault.signalState(for: id) ?? SignalState.new()
            let store = VaultSignalStore(state: state)
            let local = try localAddress()
            let sender = try ProtocolAddress(name: envelope.sender_user_id, deviceId: 1)
            let plaintext: Data
            if let preKey = try? PreKeySignalMessage(bytes: envelope.ciphertext) {
                plaintext = try signalDecryptPreKey(message: preKey, from: sender,
                                                     localAddress: local, sessionStore: store,
                                                     identityStore: store, preKeyStore: store,
                                                     signedPreKeyStore: store,
                                                     kyberPreKeyStore: store,
                                                     context: NullContext())
            } else {
                let signal = try SignalMessage(bytes: envelope.ciphertext)
                plaintext = try signalDecrypt(message: signal, from: sender, to: local,
                                              sessionStore: store, identityStore: store,
                                              context: NullContext())
            }
            let content: MessageContent
            if let structured = try? JSONDecoder().decode(MessageContent.self, from: plaintext) {
                try structured.validate()
                content = structured
            } else {
                // Compatibility with the initial text-only beta.
                guard let body = String(data: plaintext, encoding: .utf8),
                      !body.isEmpty, body.utf8.count <= 16_384,
                      !body.hasPrefix("{") else { throw MessagingError.invalidMessage }
                content = MessageContent(id: UUID(), text: body)
            }
            let message = StoredMessage(id: content.id, body: content.text,
                                        sentAt: Date(timeIntervalSince1970: TimeInterval(envelope.created_at)),
                                        isOutgoing: false, delivery: .received,
                                        envelopeID: envelope.id, ciphertext: nil,
                                        image: content.image, reactionTarget: content.reactionTarget,
                                        reaction: content.reaction)
            state = store.state
            try vault.commitReceived(state: state, message: message,
                                     envelopeID: envelope.id, for: id)
            try await gateway.acknowledgeEnvelope(envelope.id)
        }
        try check(id, generation: generation)
        // Delivery acknowledges durable recipient storage, never a read receipt.
        for message in vault.messageRecords where message.isOutgoing && message.delivery == .accepted {
            guard let envelopeID = message.envelopeID else { continue }
            let status = try await gateway.envelopeStatus(envelopeID)
            try check(id, generation: generation)
            if status == "delivered" {
                try vault.markMessageDelivered(message.id, envelopeID: envelopeID,
                                               for: id, delivery: .delivered)
            }
        }
    }

    private func flushOutbox(in id: UUID, chat: StoredChat, generation: UInt64) async throws {
        guard let roomID = chat.roomID, let remote = chat.remoteDeviceID else {
            throw MessagingError.localChatOnly
        }
        for message in vault.messageRecords where message.isOutgoing && message.delivery == .sending {
            try check(id, generation: generation)
            guard let wire = message.ciphertext else { throw MessagingError.invalidMessage }
            let envelopeID = try await gateway.sendEnvelope(roomID: roomID,
                recipientDevice: remote, kind: "message", ciphertext: wire,
                messageID: message.id.uuidString)
            try check(id, generation: generation)
            try vault.markMessageDelivered(message.id, envelopeID: envelopeID, for: id)
        }
    }
}
