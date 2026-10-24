import Foundation
import LibSignalClient

enum MessagingError: Error {
    case unavailable
    case localChatOnly
    case identityVerificationRequired(String)
    case invalidMessage
    case unsupportedGroup
}

@MainActor final class MessagingService: ObservableObject {
    @Published private(set) var pendingFingerprints: [UUID: String] = [:]
    @Published private(set) var working = false

    private let vault: LocalVault
    private let gateway: Gateway

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

    private func peerBundle(for id: UUID, chat: StoredChat) async throws -> RelayPrekeyBundle {
        if let cached = try vault.pendingPeerBundle(for: id) { return cached }
        guard let roomID = chat.roomID, let deviceID = chat.remoteDeviceID else {
            throw MessagingError.localChatOnly
        }
        let bundle = try await gateway.takePrekeys(roomID: roomID, deviceID: deviceID)
        try vault.savePendingPeerBundle(bundle, for: id)
        return bundle
    }

    func preparePeerVerification(for id: UUID) async throws -> String {
        working = true
        defer { working = false }
        let chat = try metadata(for: id)
        try await login()
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        let bundle = try await peerBundle(for: id, chat: chat)
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
        guard !body.isEmpty, body.utf8.count <= 16_384 else { throw MessagingError.invalidMessage }
        working = true
        defer { working = false }
        let chat = try metadata(for: id)
        try await login()
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        let bundle = try await peerBundle(for: id, chat: chat)
        guard try isPeerVerified(for: id) else {
            throw MessagingError.identityVerificationRequired(bundle.fingerprint)
        }
        guard let remoteDeviceID = chat.remoteDeviceID else { throw MessagingError.localChatOnly }
        var state = try vault.signalState(for: id) ?? SignalState.new()
        let store = VaultSignalStore(state: state)
        let addresses = try addresses(for: chat, bundle: bundle)
        if try store.loadSession(for: addresses.remote, context: NullContext()) == nil {
            try processPreKeyBundle(try bundle.protocolBundle(), for: addresses.remote,
                                    ourAddress: addresses.local, sessionStore: store,
                                    identityStore: store, context: NullContext())
        }
        let ciphertext = try signalEncrypt(message: Data(body.utf8), for: addresses.remote,
                                           localAddress: addresses.local, sessionStore: store,
                                           identityStore: store, context: NullContext())
        let wire = ciphertext.serialize()
        let message = StoredMessage(id: UUID(), body: body, sentAt: Date(), isOutgoing: true,
                                    delivery: .sending, envelopeID: nil, ciphertext: wire)
        state = store.state
        try vault.commitChat(state: state, message: message, for: id)
        let envelopeID = try await gateway.sendEnvelope(roomID: chat.roomID!,
                                                         recipientDevice: remoteDeviceID,
                                                         kind: "message", ciphertext: wire)
        try vault.markMessageDelivered(message.id, envelopeID: envelopeID, for: id)
    }

    func receive(in id: UUID) async throws {
        let chat = try metadata(for: id)
        try await login()
        try await ensureLocalPrekeys(for: id, roomID: chat.roomID!)
        guard try isPeerVerified(for: id) else {
            let fingerprint = try await preparePeerVerification(for: id)
            throw MessagingError.identityVerificationRequired(fingerprint)
        }
        let envelopes = try await gateway.pendingEnvelopes().filter { $0.room_id == chat.roomID }
        for envelope in envelopes {
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
            guard let body = String(data: plaintext, encoding: .utf8), !body.isEmpty else {
                throw MessagingError.invalidMessage
            }
            let message = StoredMessage(id: UUID(), body: body,
                                        sentAt: Date(timeIntervalSince1970: TimeInterval(envelope.created_at)),
                                        isOutgoing: false, delivery: .received,
                                        envelopeID: envelope.id, ciphertext: nil)
            state = store.state
            try vault.commitReceived(state: state, message: message,
                                     envelopeID: envelope.id, for: id)
            try await gateway.acknowledgeEnvelope(envelope.id)
        }
    }
}
