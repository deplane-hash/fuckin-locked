import UIKit

struct StarterSticker: Identifiable {
    let id: String
    let title: String
    let pack: String
    var asset: Data? = nil
    var tags: String = ""

    func imageData() throws -> Data {
        if let asset { try PrivateImage.validate(asset); return asset }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let image = renderer.image { context in
            let lime = UIColor(red: 182/255, green: 246/255, blue: 83/255, alpha: 1)
            let dark = UIColor(red: 31/255, green: 34/255, blue: 33/255, alpha: 1)
            lime.setFill()
            UIBezierPath(roundedRect: CGRect(x: 18, y: 18, width: 220, height: 220), cornerRadius: 72).fill()
            dark.setFill()
            if id == "bolt" {
                let bolt = UIBezierPath()
                bolt.move(to: CGPoint(x: 142, y: 44))
                for point in [CGPoint(x: 70, y: 142), CGPoint(x: 120, y: 142),
                              CGPoint(x: 106, y: 212), CGPoint(x: 186, y: 108), CGPoint(x: 136, y: 108)] {
                    bolt.addLine(to: point)
                }
                bolt.close(); bolt.fill()
            } else if id == "moon" {
                UIBezierPath(ovalIn: CGRect(x: 58, y: 50, width: 140, height: 156)).fill()
                lime.setFill()
                UIBezierPath(ovalIn: CGRect(x: 104, y: 36, width: 116, height: 140)).fill()
            } else {
                UIBezierPath(ovalIn: CGRect(x: 70, y: 82, width: 20, height: 28)).fill()
                UIBezierPath(ovalIn: CGRect(x: 166, y: 82, width: 20, height: 28)).fill()
                let smile = UIBezierPath()
                smile.move(to: CGPoint(x: 70, y: 144))
                smile.addQuadCurve(to: CGPoint(x: 186, y: 144), controlPoint: CGPoint(x: 128, y: 218))
                smile.lineWidth = 12
                dark.setStroke(); smile.stroke()
            }
        }
        guard let bytes = image.pngData() else { throw MessagingError.invalidMessage }
        try PrivateImage.validate(bytes)
        return bytes
    }
}

enum StarterStickers {
    // Original vector artwork rendered locally; no remote assets or search.
    static let items = [
        StarterSticker(id: "bolt", title: "Big energy", pack: "Energy"),
        StarterSticker(id: "smile", title: "Good mood", pack: "Energy"),
        StarterSticker(id: "moon", title: "Late night", pack: "Night")
    ]
}

struct ComposerLibrary: Codable, Equatable {
    var recentEmoji: [String] = []
    var favoriteEmoji: Set<String> = []
    var recentStickers: [String] = []
    var favoriteStickers: Set<String> = []
    var importedPacks: [StickerPack]? = nil
}
