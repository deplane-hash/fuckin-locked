import SwiftUI
import VisionKit
import CoreImage.CIFilterBuiltins
import PhotosUI
import AVFoundation

enum PairingQR {
    enum Kind: String, Sendable { case invitation, publicKey, deviceID }
    static func encode(_ value: String, kind: Kind) throws -> String {
        try validate(value, kind: kind)
        return "fl-pair-v1:\(kind.rawValue):\(value)"
    }
    static func decode(_ encoded: String, expected: Kind) throws -> String {
        guard encoded.utf8.count <= 512 else { throw MessagingError.invalidMessage }
        let prefix = "fl-pair-v1:\(expected.rawValue):"
        guard encoded.hasPrefix(prefix) else { throw MessagingError.invalidMessage }
        let value = String(encoded.dropFirst(prefix.count))
        try validate(value, kind: expected)
        return value
    }
    private static func validate(_ value: String, kind: Kind) throws {
        if kind == .publicKey {
            guard value.utf8.count <= 64, let data = Data(base64Encoded: value), data.count == 32 else {
                throw MessagingError.invalidMessage
            }
        } else {
            guard (16...128).contains(value.utf8.count), value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }) else { throw MessagingError.invalidMessage }
        }
    }
    static func readPhoto(_ bytes: Data, expected: Kind) throws -> String {
        let raster = try PrivateImage.importImage(bytes)
        guard let image = CIImage(data: raster), let detector = CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            throw MessagingError.invalidMessage
        }
        let matches = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        guard matches.count == 1, let encoded = matches.first else { throw MessagingError.invalidMessage }
        return try decode(encoded, expected: expected)
    }
}

struct PairingQRCode: View {
    let value: String
    let kind: PairingQR.Kind
    var body: some View {
        if let encoded = try? PairingQR.encode(value, kind: kind) {
            let filter = CIFilter.qrCodeGenerator()
            let _ = filter.setValue(Data(encoded.utf8), forKey: "inputMessage")
            if let output = filter.outputImage,
               let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                    from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) {
                Image(uiImage: UIImage(cgImage: image)).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220).padding(12).background(.white)
                    .accessibilityLabel("Pairing QR code. The same value is available as text.")
            }
        }
    }
}

struct PairingScanner: View {
    @EnvironmentObject private var vault: LocalVault
    @Environment(\.dismiss) private var dismiss
    let expected: PairingQR.Kind
    let completion: (String) -> Void
    @State private var photo: PhotosPickerItem?
    @State private var status = "Scan the code on the other iPhone. Scanning never approves a device."
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(status).padding()
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    Button("Allow camera scanning") {
                        AVCaptureDevice.requestAccess(for: .video) { _ in }
                    }
                    Text("The app locks during the permission prompt. Unlock and reopen this scanner afterward.")
                        .font(.footnote).padding(.horizontal)
                }
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    LivePairingScanner { encoded in accept(encoded) }
                } else {
                    Text("Live camera scanning is unavailable. Choose a QR image or enter the value manually.")
                }
                PhotosPicker(selection: $photo, matching: .images) { Text("Choose QR image") }.padding()
            }.navigationTitle("Scan pairing code")
                .toolbar { Button("Cancel") { dismiss() } }
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    let generation = vault.chatGeneration
                    Task {
                        defer { photo = nil }
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self),
                                  vault.isUnlocked, vault.chatGeneration == generation else { return }
                            let kind = expected
                            let value = try await Task.detached(priority: .userInitiated) { try PairingQR.readPhoto(data, expected: kind) }.value
                            guard vault.isUnlocked, vault.chatGeneration == generation else { return }
                            completion(value); dismiss()
                        } catch { status = "This isn't a compatible pairing code" }
                    }
                }
        }.onDisappear { photo = nil }
    }
    private func accept(_ encoded: String) {
        guard vault.isUnlocked else { return }
        do { completion(try PairingQR.decode(encoded, expected: expected)); dismiss() }
        catch { status = "This isn't a compatible pairing code" }
    }
}

private struct LivePairingScanner: UIViewControllerRepresentable {
    let completion: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            guard context.coordinator.active else { return }
            try? scanner.startScanning()
        }
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) { }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.active = false; scanner.stopScanning(); scanner.delegate = nil
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var active = true
        let completion: (String) -> Void
        init(_ completion: @escaping (String) -> Void) { self.completion = completion }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard active else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let encoded = barcode.payloadStringValue {
                    completion(encoded); return
                }
            }
        }
    }
}
