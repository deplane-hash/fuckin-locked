import Foundation
import LibSignalClient

// This entire value is serialized inside a chat's AES-GCM ciphertext. It is never
// stored in the app index without the separate chat password's content key.
struct SignalState: Codable {
    var identityKeyPair: Data
    var registrationID: UInt32
    var trustedIdentities: [String: Data] = [:]
    var preKeys: [UInt32: Data] = [:]
    var signedPreKeys: [UInt32: Data] = [:]
    var kyberPreKeys: [UInt32: Data] = [:]
    var usedKyberBaseKeys: Set<String> = []
    var sessions: [String: Data] = [:]

    static func new() -> SignalState {
        SignalState(identityKeyPair: IdentityKeyPair.generate().serialize(),
                    registrationID: UInt32.random(in: 1...16380))
    }
}

enum SignalStoreError: Error {
    case missingKey
    case identityUnverified
    case identityChanged
    case replayedPreKey
}

// Use one instance for one unlocked chat. The caller must atomically save
// `state` under that chat key after each libsignal operation before sending or
// acknowledging an envelope. This class deliberately performs no disk I/O.
final class VaultSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
                              KyberPreKeyStore, SessionStore {
    private(set) var state: SignalState

    init(state: SignalState) { self.state = state }

    private func addressKey(_ address: ProtocolAddress) -> String {
        "\(address.deviceId):\(address.name)"
    }

    func approveIdentity(_ identity: IdentityKey, for address: ProtocolAddress) throws {
        let key = addressKey(address)
        if let old = state.trustedIdentities[key], old != identity.serialize() {
            throw SignalStoreError.identityChanged
        }
        state.trustedIdentities[key] = identity.serialize()
    }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try IdentityKeyPair(bytes: state.identityKeyPair)
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        state.registrationID
    }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress,
                      context: StoreContext) throws -> IdentityChange {
        guard state.trustedIdentities[addressKey(address)] == identity.serialize() else {
            throw SignalStoreError.identityUnverified
        }
        return .newOrUnchanged
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress,
                           direction: Direction, context: StoreContext) throws -> Bool {
        state.trustedIdentities[addressKey(address)] == identity.serialize()
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let bytes = state.trustedIdentities[addressKey(address)] else { return nil }
        return try IdentityKey(bytes: bytes)
    }

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let bytes = state.preKeys[id] else { throw SignalStoreError.missingKey }
        return try PreKeyRecord(bytes: bytes)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        state.preKeys[id] = record.serialize()
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        state.preKeys[id] = nil
    }

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let bytes = state.signedPreKeys[id] else { throw SignalStoreError.missingKey }
        return try SignedPreKeyRecord(bytes: bytes)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        state.signedPreKeys[id] = record.serialize()
    }

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let bytes = state.kyberPreKeys[id] else { throw SignalStoreError.missingKey }
        return try KyberPreKeyRecord(bytes: bytes)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        state.kyberPreKeys[id] = record.serialize()
    }

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey,
                             context: StoreContext) throws {
        let marker = "\(id):\(signedPreKeyId):\(baseKey.serialize().base64EncodedString())"
        guard state.usedKyberBaseKeys.insert(marker).inserted else {
            throw SignalStoreError.replayedPreKey
        }
    }

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let bytes = state.sessions[addressKey(address)] else { return nil }
        return try SessionRecord(bytes: bytes)
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalStoreError.missingKey
            }
            return record
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress,
                      context: StoreContext) throws {
        state.sessions[addressKey(address)] = record.serialize()
    }
}
