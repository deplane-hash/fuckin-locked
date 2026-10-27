import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// All mutable state is protected by mutex. The only URL this loader serves is
// its generated private-scheme asset; it never issues an HTTP or file request.
final class PrivateMediaBuffer: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let url: URL
    private let contentType: String
    private let count: Int64
    private let mutex = NSLock()
    private var data: Data?
    init(data: Data, contentType: String) {
        self.url = URL(string: "fl-memory://\(UUID().uuidString)/clip")!
        self.data = data; self.count = Int64(data.count); self.contentType = contentType
    }
    func clear() { mutex.lock(); defer { mutex.unlock() }; data = nil }
    func bytes(offset: Int64, length: Int) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        guard let data, (0...Int64(data.count)).contains(offset), length >= 0 else { throw MessagingError.unavailable }
        let start = Int(offset)
        return data.subdata(in: start..<(start + min(length, data.count - start)))
    }
    func resourceLoader(_ loader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url == url else {
            request.finishLoading(with: URLError(.resourceUnavailable)); return true
        }
        request.contentInformationRequest?.contentType = contentType
        request.contentInformationRequest?.contentLength = count
        request.contentInformationRequest?.isByteRangeAccessSupported = true
        do {
            if let range = request.dataRequest {
                let offset = max(range.requestedOffset, range.currentOffset)
                let (end, overflow) = range.requestedOffset.addingReportingOverflow(Int64(range.requestedLength))
                guard range.requestedLength >= 0, !overflow, offset <= end || range.requestsAllDataToEndOfResource else {
                    throw MessagingError.unavailable
                }
                let length = range.requestsAllDataToEndOfResource ? Int.max : Int(end - offset)
                range.respond(with: try bytes(offset: offset, length: length))
            } else { _ = try bytes(offset: 0, length: 0) }
            request.finishLoading()
        } catch { request.finishLoading(with: URLError(.resourceUnavailable)) }
        return true
    }
}

@MainActor final class PrivateMediaSession: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing = false
    @Published private(set) var duration = 0.0
    @Published private(set) var ready = false
    private var audio: AVAudioPlayer?
    private var asset: AVURLAsset?
    private var buffer: PrivateMediaBuffer?
    private weak var vault: LocalVault?
    private var lockObserver: UUID?
    private let generation: UInt64
    private let chatID: UUID
    private var stopped = false
    private var audioSessionActive = false

    init(file: PrivateAttachment, vault: LocalVault) throws {
        guard let chatID = vault.unlockedChatID, vault.isUnlocked else { throw MessagingError.unavailable }
        try file.validate()
        self.vault = vault; self.chatID = chatID; self.generation = vault.chatGeneration
        if file.format == .audio {
            audio = try AVAudioPlayer(data: file.data)
            duration = audio?.duration ?? 0
            guard duration.isFinite, duration > 0, duration <= 60 else { throw MessagingError.invalidMessage }
            ready = true
        } else if file.format == .video {
            let buffer = PrivateMediaBuffer(data: file.data,
                contentType: file.name.lowercased().hasSuffix(".mov") ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier)
            self.buffer = buffer
            let asset = AVURLAsset(url: buffer.url, options: [
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
                AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            asset.resourceLoader.setDelegate(buffer, queue: DispatchQueue(label: "PrivateMediaLoader"))
            self.asset = asset
        } else { throw MessagingError.invalidMessage }
        lockObserver = vault.observeChatLock { [weak self] in self?.stop() }
    }
    private func check() throws {
        guard !stopped, vault?.isUnlocked == true, vault?.unlockedChatID == chatID,
              vault?.chatGeneration == generation else { throw MessagingError.unavailable }
    }
    func prepare() async throws {
        try check()
        guard let asset else { return }
        do {
            let time = try await asset.load(.duration)
            let protected = try await asset.load(.hasProtectedContent)
            let playable = try await asset.load(.isPlayable)
            try check()
            guard playable, !protected, time.seconds.isFinite, time.seconds > 0, time.seconds <= 60 else { throw MessagingError.invalidMessage }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty, tracks.count <= 2 else { throw MessagingError.invalidMessage }
            for track in tracks {
                let size = try await track.load(.naturalSize)
                try check()
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      max(size.width, size.height) <= 1920, size.width * size.height <= 2_073_600 else {
                    throw MessagingError.invalidMessage
                }
            }
            try check()
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.allowsExternalPlayback = false
            player.usesExternalPlaybackWhileExternalScreenIsActive = false
            self.player = player; duration = time.seconds; ready = true
        } catch { stop(); throw error }
    }
    func toggle() throws {
        try check()
        guard ready else { throw MessagingError.unavailable }
        if playing { audio?.pause(); player?.pause(); playing = false }
        else {
            if position >= duration - 0.05 { seek(0) }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            audioSessionActive = true
            if let audio { guard audio.play() else { throw MessagingError.unavailable } }
            player?.play(); playing = true
        }
    }
    var position: Double { audio?.currentTime ?? player?.currentTime().seconds ?? 0 }
    func checkPlayback() throws {
        try check()
        guard player?.currentItem?.status != .failed else { throw MessagingError.unavailable }
        if let audio, playing, !audio.isPlaying { playing = false }
        if let player, playing, player.timeControlStatus == .paused, position >= duration - 0.05 { playing = false }
    }
    func seek(_ seconds: Double) {
        guard (try? check()) != nil, seconds.isFinite else { return }
        let target = max(0, min(seconds, duration))
        audio?.currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        audio?.stop(); audio = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        asset?.cancelLoading(); asset?.resourceLoader.setDelegate(nil, queue: nil); asset = nil
        buffer?.clear(); buffer = nil
        if audioSessionActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        audioSessionActive = false
        playing = false; ready = false
        if let lockObserver { vault?.removeChatLockObserver(lockObserver); self.lockObserver = nil }
    }
}

private struct PrivateVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { (view.layer as? AVPlayerLayer)?.player = nil }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { return nil }
    }
}

struct PrivateMediaPlaybackView: View {
    let file: PrivateAttachment
    @EnvironmentObject private var vault: LocalVault
    @State private var session: PrivateMediaSession?
    @State private var position = 0.0
    @State private var status = "Preparing media"
    var body: some View {
        VStack(spacing: 20) {
            if let session { PrivateMediaControls(session: session, position: $position, status: $status) }
            else { Text(status) }
        }.padding()
        .task {
            do {
                let model = try PrivateMediaSession(file: file, vault: vault); session = model
                try await model.prepare()
                while !Task.isCancelled && model.ready {
                    try model.checkPlayback()
                    let current = model.position; position = current.isFinite ? max(0, current) : 0
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch { session?.stop(); status = "Media unavailable or outside supported limits" }
        }
        .onDisappear { session?.stop(); session = nil }
    }
}

private struct PrivateMediaControls: View {
    @ObservedObject var session: PrivateMediaSession
    @Binding var position: Double
    @Binding var status: String
    var body: some View {
        VStack(spacing: 20) {
            if let player = session.player { PrivateVideoSurface(player: player).frame(height: 300) }
            if session.ready {
                Button(session.playing ? "Pause" : "Play") {
                    do { try session.toggle() } catch { session.stop(); status = "Media unavailable" }
                }.frame(minWidth: 80, minHeight: 48)
                Slider(value: Binding(get: { position }, set: { session.seek($0); position = $0 }),
                       in: 0...max(0.1, session.duration)).accessibilityLabel("Playback position")
                Text("\(Int(position)) / \(Int(session.duration)) seconds").font(.caption)
            } else { Text(status) }
        }
    }
}
