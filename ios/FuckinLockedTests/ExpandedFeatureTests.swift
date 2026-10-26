import XCTest
import UIKit
import ImageIO
import CoreImage.CIFilterBuiltins
@testable import FuckinLocked

@MainActor final class ExpandedFeatureTests: XCTestCase {
    func testQRCodeImageRoundTripUsesOnlyTheExpectedType() throws {
        let code = String(repeating: "a", count: 32)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try PairingQR.encode(code, kind: .invitation).utf8)
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let image = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let bytes = try XCTUnwrap(UIImage(cgImage: image).pngData())
        XCTAssertEqual(try PairingQR.readPhoto(bytes, expected: .invitation), code)
        XCTAssertThrowsError(try PairingQR.readPhoto(bytes, expected: .publicKey))
    }
    func testPairingCodesAreTypedBoundedAndNeverURLsOrApprovalCommands() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let encoded = try PairingQR.encode(key, kind: .publicKey)
        XCTAssertEqual(try PairingQR.decode(encoded, expected: .publicKey), key)
        XCTAssertThrowsError(try PairingQR.decode(encoded, expected: .invitation))
        for bad in ["https://example.invalid", "fl-pair-v1:publicKey:invalid", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try PairingQR.decode(bad, expected: .publicKey))
        }
        let invitation = String(repeating: "a", count: 32)
        XCTAssertEqual(try PairingQR.decode(PairingQR.encode(invitation, kind: .invitation), expected: .invitation), invitation)
        XCTAssertThrowsError(try PairingQR.encode("../../../secret", kind: .deviceID))
    }

    func testFilesRejectPathsBinaryTextOversizeAndInvalidPDF() throws {
        let valid = PrivateAttachment(name: "note.txt", format: .text, data: Data("Private note\n💚".utf8))
        XCTAssertNoThrow(try valid.validate())
        XCTAssertNoThrow(try MessageContent(id: UUID(), text: "", file: valid).validate())
        for name in ["../note.txt", "folder\\note.txt", "\nsecret.txt", ""] {
            XCTAssertThrowsError(try PrivateAttachment(name: name, format: .text, data: valid.data).validate())
        }
        XCTAssertThrowsError(try PrivateAttachment(name: "bad.txt", format: .text, data: Data([0, 255])).validate())
        XCTAssertThrowsError(try PrivateAttachment(name: "large.txt", format: .text,
            data: Data(repeating: 32, count: PrivateAttachment.maxBytes + 1)).validate())
        XCTAssertThrowsError(try PrivateAttachment(name: "bad.pdf", format: .pdf, data: Data("%PDF-not-a-document".utf8)).validate())
        XCTAssertThrowsError(try MessageContent(id: UUID(), text: "", reactionTarget: UUID(), reaction: "💚", file: valid).validate())
    }

    func testFileImportUsesBoundedInPlaceReadAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("private imported file".utf8).write(to: file)
        XCTAssertEqual(try PrivateAttachment.read(file).data, Data("private imported file".utf8))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PrivateAttachment.read(link))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testPreferencesAvatarAndFileAreEncryptedAndClearOnLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("independent app password")
        var preferences = AppPreferences(); preferences.largerMessages = true; preferences.reduceAnimations = true
        try vault.setPreferences(preferences)
        let avatar = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData())
        try vault.setAvatar(avatar)
        let savedAvatar = try XCTUnwrap(vault.profileAvatar)
        try vault.createChat(title: "Test", isGroup: false, password: "independent chat password")
        let id = try XCTUnwrap(vault.chats.first?.id)
        try vault.unlockChat(id, password: "independent chat password")
        let file = PrivateAttachment(name: "secret-file.txt", format: .text, data: Data("private attachment marker".utf8))
        try vault.commitChat(state: .new(), message: StoredMessage(id: UUID(), body: "", sentAt: Date(),
            isOutgoing: true, delivery: .sending, envelopeID: nil, ciphertext: Data(repeating: 8, count: 64), file: file), for: id)
        vault.lockApp()
        XCTAssertNil(vault.profileAvatar)
        XCTAssertEqual(vault.preferences, AppPreferences())
        XCTAssertThrowsError(try vault.setPreferences(preferences))
        let bytes = try Data(contentsOf: root.appendingPathComponent("vault.bin"))
        XCTAssertNil(bytes.range(of: savedAvatar)); XCTAssertNil(bytes.range(of: file.data))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(file.name))
        let reopened = LocalVault(directory: root)
        try reopened.unlock("independent app password")
        XCTAssertEqual(reopened.preferences, preferences); XCTAssertEqual(reopened.profileAvatar, savedAvatar)
        XCTAssertTrue(reopened.messageRecords.isEmpty)
        try reopened.unlockChat(id, password: "independent chat password")
        XCTAssertEqual(reopened.messageRecords.last?.file, file)
    }

    func testGIFFrameOrderTimingAndSizeBoundsSurviveSanitization() throws {
        let bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "com.compuserve.gif" as CFString, 2, nil))
        for (index, color) in [UIColor.red, UIColor.blue].enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            CGImageDestinationAddImage(encoder, try XCTUnwrap(image.cgImage), [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: index == 0 ? 0.1 : 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let clean = try PrivateImage.importMedia(bytes as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(PrivateImage.frameDelay(source, 0), 0.1, accuracy: 0.02)
        XCTAssertEqual(PrivateImage.frameDelay(source, 1), 0.2, accuracy: 0.02)
        XCTAssertThrowsError(try PrivateImage.validateAnimation(Data(repeating: 0, count: 256_001)))
        XCTAssertThrowsError(try PrivateImage.importImage(clean), "Static avatar import must not silently flatten animation")
    }
}
