import SwiftUI
import PDFKit
import UIKit

struct PrivateAttachment: Codable, Equatable, Identifiable {
    enum Format: String, Codable { case text, pdf }
    var id: String { name }
    let name: String
    let format: Format
    let data: Data
    static let maxBytes = 512_000

    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 120,
              !name.contains("/"), !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !data.isEmpty, data.count <= Self.maxBytes else { throw MessagingError.invalidMessage }
        switch format {
        case .text:
            guard let text = String(data: data, encoding: .utf8),
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || "\n\r\t".unicodeScalars.contains($0) })
            else { throw MessagingError.invalidMessage }
        case .pdf:
            guard data.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: data),
                  !document.isLocked, (1...20).contains(document.pageCount) else { throw MessagingError.invalidMessage }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw MessagingError.invalidMessage }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite,
                      (1...14_400).contains(bounds.width), (1...14_400).contains(bounds.height) else {
                    throw MessagingError.invalidMessage
                }
            }
        }
    }

    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL, ["txt", "pdf"].contains(url.pathExtension.lowercased()) else {
            throw MessagingError.invalidMessage
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MessagingError.invalidMessage }
        var result: Result<Self, Error>?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { file in
            result = Result {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true, let size = properties.fileSize,
                      size <= maxBytes else { throw MessagingError.invalidMessage }
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                let data = try input.read(upToCount: maxBytes + 1) ?? Data()
                let attachment = Self(name: url.lastPathComponent,
                    format: url.pathExtension.lowercased() == "pdf" ? .pdf : .text, data: data)
                try attachment.validate()
                return attachment
            }
        }
        if let error { throw error }
        guard let result else { throw MessagingError.invalidMessage }
        return try result.get()
    }
}

struct PrivateAttachmentView: View {
    let attachment: PrivateAttachment
    let close: () -> Void
    private func pageImage(_ index: Int) -> UIImage? {
        guard let document = PDFDocument(data: attachment.data), let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(1, 1024 / max(bounds.width, bounds.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: bounds.width * scale, height: bounds.height * scale), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
            context.cgContext.translateBy(x: 0, y: bounds.height * scale)
            context.cgContext.scaleBy(x: scale, y: -scale)
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
    var body: some View {
        VStack {
            HStack { Text(attachment.name).font(.headline); Spacer(); Button("Close file", action: close) }.padding()
            ScrollView {
                if attachment.format == .text {
                    Text(String(data: attachment.data, encoding: .utf8) ?? "")
                        .textSelection(.disabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                } else {
                    LazyVStack {
                        ForEach(0..<(PDFDocument(data: attachment.data)?.pageCount ?? 0), id: \.self) { index in
                            if let image = pageImage(index) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .accessibilityLabel(String((PDFDocument(data: attachment.data)?.page(at: index)?.string ?? "PDF page \(index + 1)").prefix(32_768)))
                            }
                        }
                    }
                }
            }
        }.background(Palette.background).foregroundStyle(Palette.text)
        // PDFs are rasterized, never handed to a share-enabled preview, web
        // view, external URL handler, selection menu or plaintext temp file.
    }
}
