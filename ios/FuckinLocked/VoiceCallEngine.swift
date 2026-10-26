import Foundation
import AVFoundation
import UIKit
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
                                         RTCPeerConnectionDelegate, VoiceCallSession {
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
    private var sentDescription = false
    private var localCandidates: [VoiceCallPayload] = []

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

        RTCSetMinDebugLogLevel(.none)
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
        let source = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "fuckin-locked-audio")
        track.isEnabled = false
        guard peerConnection.add(track, streamIds: ["fuckin-locked-call"]) != nil else {
            peerConnection.close()
            throw VoiceCallError.peerConnectionCreationFailed
        }
        audioTrack = track
        state = isCaller ? .starting : .ringing
    }

    private func configureAudioSession() throws {
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.allowBluetoothHFP, .allowBluetoothA2DP,
                                               .defaultToSpeaker])
    }

    private func activateMicrophone() async throws {
        try checkActive()
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        try checkActive()
        guard granted else { throw VoiceCallError.microphoneDenied }
        try configureAudioSession()
        try audioSession.setActive(true)
        audioTrack?.isEnabled = true
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped, UIApplication.shared.applicationState == .active else {
            throw VoiceCallError.unavailable
        }
    }

    func startOutgoing() async throws {
        guard isCaller, !stopped else { throw VoiceCallError.unavailable }
        try await activateMicrophone()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio:
                                   kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await createOffer(constraints)
        try checkActive()
        try await setLocal(offer)
        try checkActive()
        try send(description: offer, kind: "offer")
    }

    func receive(_ signal: CallSignal) async throws {
        try checkActive()
        guard signal.callID == callID else { throw VoiceCallError.protocolError }
        do {
            try signal.validate()
            switch signal.kind {
            case "offer":
                guard !isCaller else { return }
                guard peerConnection.remoteDescription == nil else { throw VoiceCallError.protocolError }
                try await acceptOffer(signal)
            case "answer":
                guard isCaller else { return }
                guard peerConnection.remoteDescription == nil else { throw VoiceCallError.protocolError }
                try await acceptAnswer(signal)
            case "ice":
                try addCandidate(signal)
            case "hangup":
                stop(sendHangup: false)
            default:
                break
            }
        } catch {
            stop(sendHangup: false)
            state = .failed
            throw error
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
        try checkActive()
        try await setLocal(answer)
        try checkActive()
        try send(description: answer, kind: "answer")
        state = .connecting
    }

    private func acceptAnswer(_ signal: CallSignal) async throws {
        try await setRemote(decodeDescription(signal))
        try checkActive()
        state = .connecting
    }

    private func createOffer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceCallError.protocolError) }
            }
        }
    }

    private func createAnswer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.answer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceCallError.protocolError) }
            }
        }
    }

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func setRemote(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try checkActive()
        for candidate in pendingCandidates {
            try await peerConnection.add(candidate)
            try checkActive()
        }
        pendingCandidates.removeAll(keepingCapacity: false)
    }

    private func send(description: RTCSessionDescription, kind: String) throws {
        try checkActive()
        let payload = VoiceCallPayload(type: RTCSessionDescription.string(for: description.type),
                                       sdp: description.sdp, sdpMid: nil, sdpMLineIndex: nil)
        let body = try JSONEncoder().encode(payload)
        sendSignal(CallSignal(callID: callID, kind: kind, body: body))
        sentDescription = true
        for candidate in localCandidates {
            sendSignal(CallSignal(callID: callID, kind: "ice", body: try JSONEncoder().encode(candidate)))
        }
        localCandidates.removeAll(keepingCapacity: false)
    }

    private func decodeDescription(_ signal: CallSignal) throws -> RTCSessionDescription {
        let payload = try JSONDecoder().decode(VoiceCallPayload.self, from: signal.body)
        guard let type = payload.type, type == signal.kind,
              ["offer", "answer"].contains(type), let sdp = payload.sdp, !sdp.isEmpty else {
            throw VoiceCallError.protocolError
        }
        return RTCSessionDescription(type: RTCSessionDescription.type(for: type), sdp: sdp)
    }

    private func addCandidate(_ signal: CallSignal) throws {
        let payload = try JSONDecoder().decode(VoiceCallPayload.self, from: signal.body)
        guard let candidate = payload.sdp, let line = payload.sdpMLineIndex else {
            throw VoiceCallError.protocolError
        }
        let value = RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: payload.sdpMid)
        if peerConnection.remoteDescription == nil {
            guard pendingCandidates.count < 128 else { throw VoiceCallError.protocolError }
            pendingCandidates.append(value)
        } else {
            peerConnection.add(value) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    self.stop(sendHangup: false)
                    self.state = .failed
                }
            }
        }
    }

    func stop(sendHangup: Bool = true) {
        guard !stopped else { return }
        stopped = true
        if sendHangup {
            sendSignal(CallSignal(callID: callID, kind: "hangup", body: Data()))
        }
        audioTrack?.isEnabled = false
        peerConnection.delegate = nil
        peerConnection.close()
        pendingCandidates.removeAll(keepingCapacity: false)
        localCandidates.removeAll(keepingCapacity: false)
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
            case .connected, .completed: break // DTLS state below confirms connection.
            case .failed:
                self.stop(sendHangup: false)
                self.state = .failed
            case .closed, .disconnected: self.stop(sendHangup: false)
            default: self.state = .connecting
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            guard !self.stopped else { return }
            switch newState {
            case .connected: self.state = .connected
            case .failed:
                self.stop(sendHangup: false)
                self.state = .failed
            case .closed, .disconnected: self.stop(sendHangup: false)
            default: self.state = .connecting
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didGenerate candidate: RTCIceCandidate) {
        let payload = VoiceCallPayload(type: nil, sdp: candidate.sdp,
                                       sdpMid: candidate.sdpMid,
                                       sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor in
            guard !self.stopped else { return }
            if !self.sentDescription {
                guard self.localCandidates.count < 128 else {
                    self.stop(sendHangup: false); self.state = .failed; return
                }
                self.localCandidates.append(payload)
                return
            }
            guard let body = try? JSONEncoder().encode(payload) else { return }
            self.sendSignal(CallSignal(callID: self.callID, kind: "ice", body: body))
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didOpen dataChannel: RTCDataChannel) {}
}

