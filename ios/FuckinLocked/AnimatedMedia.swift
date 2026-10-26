import SwiftUI
import ImageIO

extension PrivateImage {
    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func validateAnimation(_ data: Data) throws {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), type as String == "com.compuserve.gif",
              (2...30).contains(CGImageSourceGetCount(source)) else { throw MessagingError.invalidMessage }
        var pixels = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let values = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = values[kCGImagePropertyPixelWidth] as? Int,
                  let height = values[kCGImagePropertyPixelHeight] as? Int,
                  (1...512).contains(width), (1...512).contains(height) else { throw MessagingError.invalidMessage }
            pixels += width * height
        }
        guard pixels <= 4_194_304 else { throw MessagingError.invalidMessage }
    }

    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let values = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let value = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ??
                    (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return value.isFinite ? min(1, max(0.02, value)) : 0.1
    }

    static func sanitizedGIF(_ data: Data) throws -> Data {
        try validateAnimation(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw MessagingError.invalidMessage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString,
            CGImageSourceGetCount(source), nil) else { throw MessagingError.invalidMessage }
        let values = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loops = min(100, max(0, (gif?[kCGImagePropertyGIFLoopCount] as? Int) ?? 0))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw MessagingError.invalidMessage }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: frameDelay(source, index)]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw MessagingError.invalidMessage }
        let clean = output as Data
        try validateAnimation(clean)
        return clean
    }

    static func importMedia(_ data: Data) throws -> Data {
        guard data.count <= 20_000_000 else { throw MessagingError.invalidMessage }
        return try isAnimated(data) ? sanitizedGIF(data) : importImage(data)
    }
}

// Native in-memory animation; no web view, remote GIF service, image cache or
// application-owned plaintext file. Reduce Motion displays the first frame.
struct PrivateMediaImage: UIViewRepresentable {
    let data: Data
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var vault: LocalVault
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIImageView {
        let image = UIImageView(); image.contentMode = .scaleAspectFit
        image.clipsToBounds = true; image.isUserInteractionEnabled = false
        return image
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        let paused = reduceMotion || vault.preferences.reduceAnimations
        guard context.coordinator.data != data || context.coordinator.paused != paused else { return }
        context.coordinator.data = data; context.coordinator.paused = paused
        view.stopAnimating(); view.animationImages = nil; view.image = nil
        guard (try? PrivateImage.validate(data)) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        view.image = UIImage(cgImage: first)
        guard !paused, CGImageSourceGetCount(source) > 1 else { return }
        // 20 ms ticks preserve bounded GIF timing to the nearest tick. Repeated
        // entries share UIImage references rather than re-decoding pixels.
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let raster = CGImageSourceCreateImageAtIndex(source, index, nil) else { return }
            let image = UIImage(cgImage: raster)
            let ticks = max(1, Int((PrivateImage.frameDelay(source, index) / 0.02).rounded()))
            frames.append(contentsOf: repeatElement(image, count: ticks)); duration += Double(ticks) * 0.02
        }
        let values = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        view.animationRepeatCount = min(100, max(0, (gif?[kCGImagePropertyGIFLoopCount] as? Int) ?? 0))
        view.animationImages = frames; view.animationDuration = duration; view.startAnimating()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: min(proposal.width ?? 220, 1024), height: min(proposal.height ?? 220, 1024))
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        view.stopAnimating(); view.animationImages = nil; view.image = nil; coordinator.data = nil
    }
    final class Coordinator {
        var data: Data?
        var paused = false
    }
}
