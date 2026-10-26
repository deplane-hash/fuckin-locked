import XCTest
import AVFoundation
@testable import FuckinLocked

@MainActor final class PrivateMediaTests: XCTestCase {
    private func makeVault() throws -> (LocalVault, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = LocalVault(directory: root)
        try vault.createAppPassword("separate app password")
        try vault.createChat(title: "Test", isGroup: false, password: "separate chat password")
        try vault.unlockChat(XCTUnwrap(vault.chats.first?.id), password: "separate chat password")
        return (vault, root)
    }

    private func wav() -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var bytes = Data("RIFF".utf8); bytes.append(little(UInt32(836)))
        bytes.append(Data("WAVEfmt ".utf8)); bytes.append(little(UInt32(16)))
        bytes.append(little(UInt16(1))); bytes.append(little(UInt16(1)))
        bytes.append(little(UInt32(8000))); bytes.append(little(UInt32(8000)))
        bytes.append(little(UInt16(1))); bytes.append(little(UInt16(8)))
        bytes.append(Data("data".utf8)); bytes.append(little(UInt32(800)))
        bytes.append(Data(repeating: 128, count: 800)); return bytes
    }

    func testMemoryRangesAreBoundedAndClearingRevokesFutureReads() throws {
        let secret = Data("private in-memory media".utf8)
        let buffer = PrivateMediaBuffer(data: secret, contentType: "public.mpeg-4")
        XCTAssertEqual(buffer.url.scheme, "fl-memory")
        XCTAssertEqual(try buffer.bytes(offset: 0, length: Int.max), secret)
        XCTAssertThrowsError(try buffer.bytes(offset: -1, length: 1))
        XCTAssertThrowsError(try buffer.bytes(offset: Int64.max, length: Int.max))
        XCTAssertThrowsError(try buffer.bytes(offset: 0, length: -1))
        buffer.clear()
        XCTAssertThrowsError(try buffer.bytes(offset: 0, length: 1))
    }

    func testNativeAudioHasNoAutoplayAndVaultLockStopsAndInvalidatesIt() throws {
        let (vault, root) = try makeVault(); defer { try? FileManager.default.removeItem(at: root) }
        let file = PrivateAttachment(name: "synthetic.wav", format: .audio, data: wav())
        try file.validate()
        let media = try PrivateMediaSession(file: file, vault: vault)
        XCTAssertTrue(media.ready); XCTAssertFalse(media.playing)
        XCTAssertEqual(media.duration, 0.1, accuracy: 0.02)
        vault.lockChat()
        XCTAssertFalse(media.ready); XCTAssertFalse(media.playing)
        XCTAssertThrowsError(try media.toggle())
    }

    func testNativeVideoLoadsFromMemoryAndLockRemovesPlayer() async throws {
        // Public synthetic test fixture only. Production media code never
        // creates this temporary file or writes received content to disk.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetBytesPerRow(frame) * 16)
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<2 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 5)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        let file = PrivateAttachment(name: "synthetic.mp4", format: .video, data: try Data(contentsOf: output))
        let (vault, root) = try makeVault(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try PrivateMediaSession(file: file, vault: vault)
        defer { media.stop() }
        try await media.prepare()
        XCTAssertTrue(media.ready); XCTAssertFalse(media.playing)
        XCTAssertFalse(try XCTUnwrap(media.player).allowsExternalPlayback)
        vault.lockApp()
        XCTAssertNil(media.player); XCTAssertFalse(media.ready)
        XCTAssertThrowsError(try media.toggle())
    }
}
