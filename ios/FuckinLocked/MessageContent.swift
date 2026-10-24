import Foundation
import UIKit
import ImageIO

// This schema describes the content inside a libsignal message; it is not a
// cryptographic protocol. All fields, including reaction targets, are encrypted.
struct MessageContent: Codable {
    var version: Int = 1
    var id: UUID
    var text: String
    var image: Data?
    var reactionTarget: UUID?
    var reaction: String?
    var groupID: String? = nil
    var callSignal: CallSignal? = nil

    static let reactions = ["💚", "👍", "😂", "😮", "😢", "🔥"]

    func validate() throws {
        guard version == 1, text.utf8.count <= 16_384 else { throw MessagingError.invalidMessage }
        if let callSignal {
            guard text.isEmpty, image == nil, reactionTarget == nil, reaction == nil else {
                throw MessagingError.invalidMessage
            }
            try callSignal.validate()
            return
        }
        if let groupID {
            guard !groupID.isEmpty, groupID.utf8.count <= 128,
                  groupID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
            else { throw MessagingError.invalidMessage }
        }
        if let reactionTarget {
            guard reactionTarget != id, image == nil, text.isEmpty,
                  let reaction, Self.reactions.contains(reaction) else { throw MessagingError.invalidMessage }
        } else {
            guard reaction == nil, !text.isEmpty || image != nil else { throw MessagingError.invalidMessage }
        }
        if let image { try PrivateImage.validate(image) }
    }
}

struct CallSignal: Codable, Equatable {
    static let maxBytes = 64_000
    static let kinds: Set<String> = ["offer", "answer", "ice", "hangup"]
    let callID: UUID
    let kind: String
    let body: Data

    func validate() throws {
        guard Self.kinds.contains(kind), body.count <= Self.maxBytes else {
            throw MessagingError.invalidMessage
        }
    }
}

enum PrivateImage {
    static let maxBytes = 256_000

    static func validate(_ bytes: Data) throws {
        guard bytes.count <= maxBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 4_194_304 else { throw MessagingError.invalidMessage }
    }

    // Load a bounded raster into memory and re-encode without EXIF/GPS metadata.
    // No application-owned plaintext file or thumbnail cache is created.
    static func importImage(_ bytes: Data) throws -> Data {
        guard bytes.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(bytes as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { throw MessagingError.invalidMessage }
        let image = UIImage(cgImage: raster)
        for quality in [0.8, 0.6, 0.4, 0.2] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes {
                try validate(data)
                return data
            }
        }
        throw MessagingError.invalidMessage
    }
}
