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
    var file: PrivateAttachment? = nil

    static let reactions = ["💚", "👍", "😂", "😮", "😢", "🔥"]

    func validate() throws {
        guard version == 1, text.utf8.count <= 16_384 else { throw MessagingError.invalidMessage }
        if let callSignal {
            guard text.isEmpty, image == nil, file == nil, reactionTarget == nil, reaction == nil,
                  groupID == nil else {
                throw MessagingError.invalidMessage
            }
            // Stale commands must still advance/acknowledge the authenticated
            // Signal session so they cannot block later ordinary messages.
            try callSignal.validate(requireFresh: false)
            return
        }
        if let groupID {
            guard !groupID.isEmpty, groupID.utf8.count <= 128,
                  groupID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
            else { throw MessagingError.invalidMessage }
        }
        if let reactionTarget {
            guard reactionTarget != id, image == nil, file == nil, text.isEmpty,
                  let reaction, Self.reactions.contains(reaction) else { throw MessagingError.invalidMessage }
        } else {
            guard reaction == nil, !text.isEmpty || image != nil || file != nil,
                  image == nil || file == nil else { throw MessagingError.invalidMessage }
        }
        if let image { try PrivateImage.validate(image) }
        if let file { try file.validate() }
    }
}

struct CallSignal: Codable, Equatable {
    static let maxBytes = 64_000
    static let kinds: Set<String> = ["offer", "answer", "ice", "hangup"]
    let callID: UUID
    let kind: String
    let body: Data
    let expiresAt: Date

    init(callID: UUID, kind: String, body: Data, expiresAt: Date = Date().addingTimeInterval(90)) {
        self.callID = callID; self.kind = kind; self.body = body; self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case callID, kind, body, expiresAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(UUID.self, forKey: .callID)
        kind = try values.decode(String.self, forKey: .kind)
        body = try values.decode(Data.self, forKey: .body)
        // Old history remains readable, but old call commands cannot ring.
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt) ?? .distantPast
    }

    func validate(requireFresh: Bool = true) throws {
        let remaining = expiresAt.timeIntervalSinceNow
        guard Self.kinds.contains(kind), body.count <= Self.maxBytes,
              !requireFresh || (remaining > 0 && remaining <= 120) else {
            throw MessagingError.invalidMessage
        }
    }
}

enum PrivateImage {
    static let maxBytes = 256_000

    static func validate(_ bytes: Data) throws {
        guard bytes.count <= maxBytes else { throw MessagingError.invalidMessage }
        if isAnimated(bytes) { try validateAnimation(bytes); return }
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
