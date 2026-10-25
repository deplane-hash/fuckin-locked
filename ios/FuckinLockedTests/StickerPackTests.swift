import XCTest
import ImageIO
@testable import FuckinLocked

@MainActor final class StickerPackTests: XCTestCase {
    private func pack(id: String = "my-pack", ids: [String] = ["hello"]) throws -> StickerPack {
        let image = try StarterStickers.items[0].imageData()
        return StickerPack(schema: 2, id: id, name: "Private pack title", author: "Original artist",
                           license: "CC0-1.0", stickers: ids.map {
            StickerPack.Asset(id: $0, name: "Hello", tags: ["greeting"], image: image)
        })
    }

    func testPackRoundTripAndOldLibraryCompatibility() throws {
        let original = try pack()
        let decoded = try StickerPack.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.items.first?.id, "import:my-pack:hello")
        XCTAssertNoThrow(try decoded.items[0].imageData())
        let old = try JSONDecoder().decode(ComposerLibrary.self, from:
            Data(#"{"recentEmoji":[],"favoriteEmoji":[],"recentStickers":[],"favoriteStickers":[]}"#.utf8))
        XCTAssertNil(old.importedPacks)
    }

    func testRejectsTraversalRemoteIDsDuplicateIDsAndOversizedDocuments() throws {
        for invalid in ["../escape", "https://example.invalid", "", "import:collision"] {
            XCTAssertThrowsError(try pack(id: invalid).validate())
        }
        XCTAssertThrowsError(try pack(ids: ["same", "same"]).validate())
        XCTAssertThrowsError(try StickerPack.decode(Data(repeating: 32, count: StickerPack.maxDocumentBytes + 1)))
        var library = ComposerLibrary()
        try library.add(pack())
        XCTAssertThrowsError(try library.add(pack()))
        XCTAssertEqual(library.importedPacks?.count, 1)
    }

    func testRejectsUnsupportedSchemaAndMalformedArtwork() throws {
        let invalid = StickerPack(schema: 1, id: "pack", name: "Pack", author: "Artist", license: "CC0",
                                  stickers: [StickerPack.Asset(id: "one", name: "One", tags: [], image: Data([0]))])
        XCTAssertThrowsError(try invalid.validate())
        let malformed = StickerPack(schema: 2, id: "pack", name: "Pack", author: "Artist", license: "CC0",
                                  stickers: invalid.stickers)
        XCTAssertThrowsError(try malformed.validate())
    }

    func testImportStripsGPSAndRejectsAnimation() throws {
        let original = try pack()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original.stickers[0].image as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let tagged = NSMutableData()
        let jpeg = try XCTUnwrap(CGImageDestinationCreateWithData(tagged, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(jpeg, image, [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.0, kCGImagePropertyGPSLongitude: 16.0,
            kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitudeRef: "E"
        ]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(jpeg))
        let taggedSource = try XCTUnwrap(CGImageSourceCreateWithData(tagged, nil))
        let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(taggedSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary])
        let asset = StickerPack.Asset(id: "hello", name: "Hello", tags: [], image: tagged as Data)
        let taggedPack = StickerPack(schema: 2, id: "pack", name: "Pack", author: "Artist",
                                    license: "CC0", stickers: [asset])
        let clean = try StickerPack.decode(JSONEncoder().encode(taggedPack))
        let cleanSource = try XCTUnwrap(CGImageSourceCreateWithData(clean.stickers[0].image as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let animated = NSMutableData()
        let gif = try XCTUnwrap(CGImageDestinationCreateWithData(animated, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(gif, image, nil)
        CGImageDestinationAddImage(gif, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        XCTAssertThrowsError(try PrivateImage.validate(animated as Data))
    }

    func testImportedArtworkAndAttributionStayChatEncryptedAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("separate app password")
        try vault.createChat(title: "Friend", isGroup: false, password: "separate chat password")
        let id = try XCTUnwrap(vault.chats.first?.id)
        try vault.unlockChat(id, password: "separate chat password")
        var library = ComposerLibrary()
        try library.add(pack())
        try vault.saveComposerLibrary(library, for: id)
        vault.lockApp()
        XCTAssertThrowsError(try vault.composerLibrary(for: id))
        let saved = try Data(contentsOf: root.appendingPathComponent("vault.bin"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("Private pack title"))
        XCTAssertFalse(saved.range(of: try pack().stickers[0].image) != nil)
        let restarted = LocalVault(directory: root)
        try restarted.unlock("separate app password")
        XCTAssertThrowsError(try restarted.composerLibrary(for: id))
        try restarted.unlockChat(id, password: "separate chat password")
        XCTAssertEqual(try restarted.composerLibrary(for: id), library)
    }

    func testImporterRejectsSymlinksAndDoesNotCopySourceIntoVault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("pack.json")
        try JSONEncoder().encode(pack()).write(to: source)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try StickerPack.read(link))
        XCTAssertEqual(try StickerPack.read(source).id, "my-pack")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
}
