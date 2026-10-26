import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// A single bounded JSON document avoids archive paths, symlinks, executable
// files and URL fetching. Imported artwork is stored only in chat ciphertext.
struct StickerPack: Codable, Equatable, Identifiable {
    struct Asset: Codable, Equatable {
        let id: String
        let name: String
        let tags: [String]
        let image: Data
    }

    static let maxDocumentBytes = 3_000_000
    static let maxLibraryBytes = 8_000_000
    let schema: Int
    let id: String
    let name: String
    let author: String
    let license: String
    let stickers: [Asset]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxDocumentBytes else { throw MessagingError.invalidMessage }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        try pack.validate()
        let sanitized = try pack.stickers.map { asset -> Asset in
            if PrivateImage.isAnimated(asset.image) {
                return Asset(id: asset.id, name: asset.name, tags: asset.tags,
                             image: try PrivateImage.sanitizedGIF(asset.image))
            }
            let output = NSMutableData()
            guard let source = CGImageSourceCreateWithData(asset.image as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw MessagingError.invalidMessage
            }
            // Encode pixels only. EXIF/GPS and source metadata are not copied.
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw MessagingError.invalidMessage }
            return Asset(id: asset.id, name: asset.name, tags: asset.tags, image: output as Data)
        }
        let clean = Self(schema: pack.schema, id: pack.id, name: pack.name,
                         author: pack.author, license: pack.license, stickers: sanitized)
        try clean.validate()
        return clean
    }

    func validate() throws {
        guard [2, 3].contains(schema), Self.validID(id), Self.validText(name, limit: 80),
              Self.validText(author, limit: 120), Self.validText(license, limit: 1000),
              (1...32).contains(stickers.count),
              Set(stickers.map(\.id)).count == stickers.count,
              stickers.reduce(0, { $0 + $1.image.count }) <= 2_000_000 else {
            throw MessagingError.invalidMessage
        }
        for asset in stickers {
            guard Self.validID(asset.id), Self.validText(asset.name, limit: 80),
                  asset.tags.count <= 12,
                  asset.tags.allSatisfy({ Self.validText($0, limit: 40) }) else {
                throw MessagingError.invalidMessage
            }
            if schema == 2 && PrivateImage.isAnimated(asset.image) { throw MessagingError.invalidMessage }
            try PrivateImage.validate(asset.image)
            guard let source = CGImageSourceCreateWithData(asset.image as CFData, nil),
                  let type = CGImageSourceGetType(source),
                  ["public.png", "public.jpeg", "com.compuserve.gif"].contains(type as String),
                  schema == 3 || type as String != "com.compuserve.gif",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width <= 1024, height <= 1024 else { throw MessagingError.invalidMessage }
        }
    }

    var items: [StarterSticker] {
        stickers.map { asset in
            StarterSticker(id: "import:\(id):\(asset.id)", title: asset.name,
                           pack: name, asset: asset.image, tags: asset.tags.joined(separator: " "))
        }
    }

    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw MessagingError.invalidMessage }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw MessagingError.invalidMessage
        }
        var coordinationError: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                       error: &coordinationError) { coordinated in
            result = Result { try readCoordinated(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw MessagingError.invalidMessage }
        return try result.get()
    }

    private static func readCoordinated(_ url: URL) throws -> Self {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size <= maxDocumentBytes else {
            throw MessagingError.invalidMessage
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        // A bounded read also handles files changing after the size check.
        let data = try input.read(upToCount: maxDocumentBytes + 1) ?? Data()
        return try decode(data)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value.utf8.count <= limit &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

// Explicit open-in-place policy: never ask iOS to import a plaintext copy into
// the app's Documents/Inbox. Cloud providers still control their own caches.
struct StickerPackPicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let completion: (Result<URL, Error>) -> Void

    init(allowedTypes: [UTType] = [.json], completion: @escaping (Result<URL, Error>) -> Void) {
        self.allowedTypes = allowedTypes; self.completion = completion
    }

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard urls.count == 1, let url = urls.first else {
                completion(.failure(MessagingError.invalidMessage)); return
            }
            completion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.failure(CocoaError(.userCancelled)))
        }
    }
}

extension ComposerLibrary {
    mutating func add(_ pack: StickerPack) throws {
        try pack.validate()
        var packs = importedPacks ?? []
        guard packs.count < 8, !packs.contains(where: { $0.id == pack.id }) else {
            throw MessagingError.invalidMessage
        }
        packs.append(pack)
        guard packs.flatMap(\.stickers).reduce(0, { $0 + $1.image.count }) <= StickerPack.maxLibraryBytes else {
            throw MessagingError.invalidMessage
        }
        importedPacks = packs
    }
}
