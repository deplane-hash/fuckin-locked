import Foundation
import LibSignalClient
import CryptoKit

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
    var nextPreKeyID: UInt32 = 1
    var nextSignedPreKeyID: UInt32 = 1
    var nextKyberPreKeyID: UInt32 = 1

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

struct SignalPublicBundle {
    let registrationID: UInt32
    let deviceNumber: UInt32
    let identityKey: Data
    let signedPreKeyID: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let oneTimePreKeyID: UInt32
    let oneTimePreKey: Data
    let kyberPreKeyID: UInt32
    let kyberPreKey: Data
    let kyberPreKeySignature: Data

    var requestBody: [String: Any] {
        ["registration_id": registrationID, "device_number": deviceNumber,
         "identity_key": identityKey.base64EncodedString(),
         "signed_prekey_id": signedPreKeyID,
         "signed_prekey": signedPreKey.base64EncodedString(),
         "signed_prekey_signature": signedPreKeySignature.base64EncodedString(),
         "one_time_prekey_id": oneTimePreKeyID,
         "one_time_prekey": oneTimePreKey.base64EncodedString(),
         "kyber_prekey_id": kyberPreKeyID,
         "kyber_prekey": kyberPreKey.base64EncodedString(),
         "kyber_prekey_signature": kyberPreKeySignature.base64EncodedString()]
    }
}

extension RelayPrekeyBundle {
    func protocolBundle() throws -> PreKeyBundle {
        try PreKeyBundle(registrationId: registration_id, deviceId: device_number,
                         prekeyId: one_time_prekey_id, prekey: PublicKey(one_time_prekey),
                         signedPrekeyId: signed_prekey_id, signedPrekey: PublicKey(signed_prekey),
                         signedPrekeySignature: signed_prekey_signature,
                         identity: IdentityKey(bytes: identity_key),
                         kyberPrekeyId: kyber_prekey_id, kyberPrekey: KEMPublicKey(kyber_prekey),
                         kyberPrekeySignature: kyber_prekey_signature)
    }

    var fingerprint: String {
        SHA256.hash(data: identity_key).map { String(format: "%02X", $0) }.joined()
    }
}

// Use one instance for one unlocked chat. The caller must atomically save
// `state` under that chat key after each libsignal operation before sending or
// acknowledging an envelope. This class deliberately performs no disk I/O.
final class VaultSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
                              KyberPreKeyStore, SessionStore {
    private(set) var state: SignalState

    init(state: SignalState) { self.state = state }

    func generatePublicBundle(deviceNumber: UInt32 = 1) throws -> SignalPublicBundle {
        guard (1...127).contains(deviceNumber),
              state.nextPreKeyID < UInt32.max,
              state.nextSignedPreKeyID < UInt32.max,
              state.nextKyberPreKeyID < UInt32.max else { throw SignalStoreError.missingKey }
        let identity = try identityKeyPair(context: NullContext())
        let ecPrivate = PrivateKey.generate()
        let signedPrivate = PrivateKey.generate()
        let kyberPair = KEMKeyPair.generate()
        let signedPublic = signedPrivate.publicKey.serialize()
        let kyberPublic = kyberPair.publicKey.serialize()
        let signedSignature = identity.privateKey.generateSignature(message: signedPublic)
        let kyberSignature = identity.privateKey.generateSignature(message: kyberPublic)
        let oneTimeID = state.nextPreKeyID
        let signedID = state.nextSignedPreKeyID
        let kyberID = state.nextKyberPreKeyID
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        try storePreKey(PreKeyRecord(id: oneTimeID, privateKey: ecPrivate),
                        id: oneTimeID, context: NullContext())
        try storeSignedPreKey(SignedPreKeyRecord(id: signedID, timestamp: timestamp,
                                                 privateKey: signedPrivate, signature: signedSignature),
                              id: signedID, context: NullContext())
        try storeKyberPreKey(KyberPreKeyRecord(id: kyberID, timestamp: timestamp,
                                               keyPair: kyberPair, signature: kyberSignature),
                             id: kyberID, context: NullContext())
        state.nextPreKeyID += 1
        state.nextSignedPreKeyID += 1
        state.nextKyberPreKeyID += 1
        return SignalPublicBundle(registrationID: state.registrationID,
                                  deviceNumber: deviceNumber,
                                  identityKey: identity.identityKey.serialize(),
                                  signedPreKeyID: signedID, signedPreKey: signedPublic,
                                  signedPreKeySignature: signedSignature,
                                  oneTimePreKeyID: oneTimeID,
                                  oneTimePreKey: ecPrivate.publicKey.serialize(),
                                  kyberPreKeyID: kyberID, kyberPreKey: kyberPublic,
                                  kyberPreKeySignature: kyberSignature)
    }

    func currentPublicBundle(deviceNumber: UInt32 = 1) throws -> SignalPublicBundle {
        guard let oneTimeID = state.preKeys.keys.sorted().first,
              let signedID = state.signedPreKeys.keys.sorted().first,
              let kyberID = state.kyberPreKeys.keys.sorted().first else {
            throw SignalStoreError.missingKey
        }
        let oneTime = try loadPreKey(id: oneTimeID, context: NullContext())
        let signed = try loadSignedPreKey(id: signedID, context: NullContext())
        let kyber = try loadKyberPreKey(id: kyberID, context: NullContext())
        return SignalPublicBundle(
            registrationID: state.registrationID,
            deviceNumber: deviceNumber,
            identityKey: try identityKeyPair(context: NullContext()).identityKey.serialize(),
            signedPreKeyID: signedID,
            signedPreKey: try signed.publicKey().serialize(),
            signedPreKeySignature: signed.signature,
            oneTimePreKeyID: oneTimeID,
            oneTimePreKey: try oneTime.publicKey().serialize(),
            kyberPreKeyID: kyberID,
            kyberPreKey: try kyber.publicKey().serialize(),
            kyberPreKeySignature: kyber.signature)
    }

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
