import Foundation
import AVFoundation
import WebRTC

/// The signaling payload is carried inside a normal libsignal message.  SDP
/// and ICE candidates are therefore ciphertext at the relay; the relay only
/// sees the usual envelope metadata. WebRTC then provides DTLS-SRTP media
/// encryption on the TURN-only transport.
struct VoiceCallPayload: Codable, Equatable {
    var type: String?
    var sdp: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

enum VoiceCallState: Equatable {
    case idle
    case starting
    case ringing
    case connecting
    case connected
    case ended
    case failed
}

enum VoiceCallError: Error {
    case invalidTURN
    case microphoneDenied
    case unavailable
    case protocolError
    case peerConnectionCreationFailed
}

/// A two-party, audio-only WebRTC call. This type deliberately accepts only a
/// TURN-over-TLS URI and configures relay-only ICE. There is no STUN, host, or
/// direct peer fallback, so calls fail closed when the configured route is
/// unavailable.
@MainActor final class VoiceCallEngine: NSObject, ObservableObject,
                                         RTCPeerConnectionDelegate {
    @Published private(set) var state: VoiceCallState = .idle

    let callID: UUID
    let isCaller: Bool
    private let sendSignal: (CallSignal) -> Void
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private let audioSession = AVAudioSession.sharedInstance()
    private var audioTrack: RTCAudioTrack?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var stopped = false

    init(callID: UUID, isCaller: Bool, turn: CallTURN,
         sendSignal: @escaping (CallSignal) -> Void) throws {
        guard turn.url.lowercased().hasPrefix("turns:"),
              !turn.username.isEmpty, !turn.credential.isEmpty,
              URL(string: turn.url) != nil else { throw VoiceCallError.invalidTURN }
        self.callID = callID
        self.isCaller = isCaller
        self.sendSignal = sendSignal

        let server = RTCIceServer(urlStrings: [turn.url],
                                  username: turn.username,
                                  credential: turn.credential,
                                  tlsCertPolicy: .secure)
        let configuration = RTCConfiguration()
        configuration.iceServers = [server]
        configuration.iceTransportPolicy = .relay
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.sdpSemantics = .unifiedPlan

        factory = RTCPeerConnectionFactory()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration,
                                                       constraints: constraints,
                                                       delegate: nil) else {
            throw VoiceCallError.peerConnectionCreationFailed
        }
        peerConnection = connection
        super.init()
        peerConnection.delegate = self
        try configureAudioSession()
        let source = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "fuckin-locked-audio")
        guard peerConnection.add(track, streamIds: ["fuckin-locked-call"]) != nil else {
            throw VoiceCallError.peerConnectionCreationFailed
        }
        audioTrack = track
        state = isCaller ? .starting : .ringing
    }

    deinit {
        peerConnection.delegate = nil
    }

    private func configureAudioSession() throws {
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.allowBluetooth, .allowBluetoothA2DP,
                                               .defaultToSpeaker])
    }

    private func activateMicrophone() async throws {
        let granted = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else { throw VoiceCallError.microphoneDenied }
        try audioSession.setActive(true)
    }

    func startOutgoing() async throws {
        guard isCaller, !stopped else { throw VoiceCallError.unavailable }
        try await activateMicrophone()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio:
                                   kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await createOffer(constraints)
        try await setLocal(offer)
        try send(description: offer, kind: "offer")
    }

    func receive(_ signal: CallSignal) {
        guard !stopped, signal.callID == callID else { return }
        do {
            try signal.validate()
            switch signal.kind {
            case "offer":
                guard !isCaller else { return }
                Task { @MainActor in try await self.acceptOffer(signal) }
            case "answer":
                guard isCaller else { return }
                Task { @MainActor in try await self.acceptAnswer(signal) }
            case "ice":
                try addCandidate(signal)
            case "hangup":
                stop(sendHangup: false)
            default:
                break
            }
        } catch {
            state = .failed
        }
    }

    private func acceptOffer(_ signal: CallSignal) async throws {
        try await activateMicrophone()
        let description = try decodeDescription(signal)
        try await setRemote(description)
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio:
                                   kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let answer = try await createAnswer(constraints)
        try await setLocal(answer)
        try send(description: answer, kind: "answer")
        state = .connecting
    }

    private func acceptAnswer(_ signal: CallSignal) async throws {
        try await setRemote(decodeDescription(signal))
        state = .connecting
    }

    private func createOffer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceCallError.protocolError) }
            }
        }
    }

    private func createAnswer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceCallError.protocolError) }
            }
        }
    }

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func setRemote(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        for candidate in pendingCandidates {
            peerConnection.add(candidate) { _ in }
        }
        pendingCandidates.removeAll(keepingCapacity: false)
    }

    private func send(description: RTCSessionDescription, kind: String) throws {
        let payload = VoiceCallPayload(type: RTCSessionDescription.string(for: description.type),
                                       sdp: description.sdp, sdpMid: nil, sdpMLineIndex: nil)
        let body = try JSONEncoder().encode(payload)
        sendSignal(CallSignal(callID: callID, kind: kind, body: body))
    }

    private func decodeDescription(_ signal: CallSignal) throws -> RTCSessionDescription {
        let payload = try JSONDecoder().decode(VoiceCallPayload.self, from: signal.body)
        guard let type = payload.type, let sdp = payload.sdp else { throw VoiceCallError.protocolError }
        return RTCSessionDescription(type: RTCSessionDescription.type(for: type), sdp: sdp)
    }

    private func addCandidate(_ signal: CallSignal) throws {
        let payload = try JSONDecoder().decode(VoiceCallPayload.self, from: signal.body)
        guard let candidate = payload.sdp, let line = payload.sdpMLineIndex else {
            throw VoiceCallError.protocolError
        }
        let value = RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: payload.sdpMid)
        if peerConnection.remoteDescription == nil {
            pendingCandidates.append(value)
        } else {
            peerConnection.add(value) { _ in }
        }
    }

    func stop(sendHangup: Bool = true) {
        guard !stopped else { return }
        stopped = true
        if sendHangup {
            sendSignal(CallSignal(callID: callID, kind: "hangup", body: Data()))
        }
        peerConnection.close()
        audioTrack = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        state = .ended
    }

    // MARK: RTCPeerConnectionDelegate

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard !self.stopped else { return }
            switch newState {
            case .connected, .completed: self.state = .connected
            case .failed: self.state = .failed
            case .closed, .disconnected: self.stop(sendHangup: false)
            default: self.state = .connecting
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard !self.stopped else { return }
            let payload = VoiceCallPayload(type: nil, sdp: candidate.sdp,
                                           sdpMid: candidate.sdpMid,
                                           sdpMLineIndex: candidate.sdpMLineIndex)
            guard let body = try? JSONEncoder().encode(payload) else { return }
            self.sendSignal(CallSignal(callID: self.callID, kind: "ice", body: body))
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didOpen dataChannel: RTCDataChannel) {}
}

