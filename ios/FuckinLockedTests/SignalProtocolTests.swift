import XCTest
import LibSignalClient
@testable import FuckinLocked

@MainActor final class SignalProtocolTests: XCTestCase {
    func testTwoPersistentStoresEncryptDecryptAndReply() throws {
        let aliceAddress = try ProtocolAddress(name: "alice", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob", deviceId: 1)
        var alice = VaultSignalStore(state: .new())
        var bob = VaultSignalStore(state: .new())
        let bobBundle = try bob.generatePublicBundle()
        let bobProtocolBundle = try PreKeyBundle(
            registrationId: bobBundle.registrationID,
            deviceId: bobBundle.deviceNumber,
            prekeyId: bobBundle.oneTimePreKeyID,
            prekey: PublicKey(bobBundle.oneTimePreKey),
            signedPrekeyId: bobBundle.signedPreKeyID,
            signedPrekey: PublicKey(bobBundle.signedPreKey),
            signedPrekeySignature: bobBundle.signedPreKeySignature,
            identity: IdentityKey(bytes: bobBundle.identityKey),
            kyberPrekeyId: bobBundle.kyberPreKeyID,
            kyberPrekey: KEMPublicKey(bobBundle.kyberPreKey),
            kyberPrekeySignature: bobBundle.kyberPreKeySignature)

        try alice.approveIdentity(bobProtocolBundle.identityKey, for: bobAddress)
        try processPreKeyBundle(bobProtocolBundle, for: bobAddress, ourAddress: aliceAddress,
                                sessionStore: alice, identityStore: alice, context: NullContext())
        let first = try signalEncrypt(message: Data("hello from alice".utf8), for: bobAddress,
                                      localAddress: aliceAddress, sessionStore: alice,
                                      identityStore: alice, context: NullContext())
        let preKeyMessage = try PreKeySignalMessage(bytes: first.serialize())
        try bob.approveIdentity(IdentityKey(publicKey: preKeyMessage.identityKey), for: aliceAddress)
        let restoredBob = try JSONDecoder().decode(SignalState.self,
            from: JSONEncoder().encode(bob.state))
        bob = VaultSignalStore(state: restoredBob)
        let plaintext = try signalDecryptPreKey(message: preKeyMessage, from: aliceAddress,
                                                localAddress: bobAddress, sessionStore: bob,
                                                identityStore: bob, preKeyStore: bob,
                                                signedPreKeyStore: bob, kyberPreKeyStore: bob,
                                                context: NullContext())
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), "hello from alice")

        let restoredAlice = try JSONDecoder().decode(SignalState.self,
            from: JSONEncoder().encode(alice.state))
        alice = VaultSignalStore(state: restoredAlice)
        let reply = try signalEncrypt(message: Data("hello from bob".utf8), for: aliceAddress,
                                      localAddress: bobAddress, sessionStore: bob,
                                      identityStore: bob, context: NullContext())
        let replyMessage = try SignalMessage(bytes: reply.serialize())
        let replyPlaintext = try signalDecrypt(message: replyMessage, from: bobAddress,
                                               to: aliceAddress, sessionStore: alice,
                                               identityStore: alice, context: NullContext())
        XCTAssertEqual(String(data: replyPlaintext, encoding: .utf8), "hello from bob")
    }
}
