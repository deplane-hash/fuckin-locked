import Foundation
import SwiftUI
import UIKit

/// Coordinates one call for the currently unlocked one-to-one chat. Signaling
/// is deliberately sourced from StoredMessage records, so a call cannot be
/// created from an unauthenticated or unbound relay event.
@MainActor final class VoiceCallCoordinator: ObservableObject {
    @Published private(set) var state: VoiceCallState = .idle
    @Published private(set) var status = ""

    private let id: UUID
    private let vault: LocalVault
    private let gateway: Gateway
    private let messaging: MessagingService
    private var engine: VoiceCallEngine?
    private var callID: UUID?
    private var consumedMessages = Set<UUID>()
    private var stateTask: Task<Void, Never>?
    private var lifecycleToken: NSObjectProtocol?

    init(id: UUID, vault: LocalVault, gateway: Gateway, messaging: MessagingService) {
        self.id = id
        self.vault = vault
        self.gateway = gateway
        self.messaging = messaging
        lifecycleToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(sendHangup: false) }
        }
    }

    deinit {
        stateTask?.cancel()
    }

    var isActive: Bool {
        switch state {
        case .starting, .ringing, .connecting, .connected: return true
        default: return false
        }
    }

    func startOutgoing() async {
        guard engine == nil else { return }
        guard (try? messaging.isPeerVerified(for: id)) == true else {
            status = "Verify this device before calling"
            return
        }
        do {
            try await gateway.login(deviceID: vault.deviceID)
            try await gateway.requireCallCapabilities()
            let turn = try await gateway.callTURN()
            let newID = UUID()
            let call = try makeEngine(callID: newID, isCaller: true, turn: turn)
            engine = call
            callID = newID
            observe(call)
            try await call.startOutgoing()
            status = "Calling…"
        } catch VoiceCallError.microphoneDenied {
            status = "Microphone access is required for calls"
            stop(sendHangup: false)
        } catch {
            status = "Encrypted call unavailable"
            stop(sendHangup: false)
        }
    }

    /// Process newly decrypted call signals. The caller passes all records;
    /// this method only consumes each record once and never treats an outgoing
    /// signal as a remote command.
    func consume(_ records: [StoredMessage]) {
        for record in records where !record.isOutgoing {
            guard let signal = record.callSignal, !consumedMessages.contains(record.id) else { continue }
            consumedMessages.insert(record.id)
            Task { @MainActor in await self.handleIncoming(signal, receivedAt: record.sentAt) }
        }
    }

    private func handleIncoming(_ signal: CallSignal, receivedAt: Date) async {
        // Do not turn a stale persisted offer into an unexpected call after a
        // restart. Answers/ICE/hangups are accepted only for an active call.
        let freshOffer = signal.kind == "offer" && Date().timeIntervalSince(receivedAt) <= 300
        guard freshOffer || engine != nil else {
            if signal.kind == "hangup" { stop(sendHangup: false) }
            return
        }
        do {
            if engine == nil {
                try await gateway.login(deviceID: vault.deviceID)
                try await gateway.requireCallCapabilities()
                let turn = try await gateway.callTURN()
                let call = try makeEngine(callID: signal.callID, isCaller: false, turn: turn)
                engine = call
                callID = signal.callID
                observe(call)
            }
            guard callID == signal.callID else { return }
            engine?.receive(signal)
            status = "Incoming encrypted call"
        } catch {
            status = "Encrypted call unavailable"
            stop(sendHangup: false)
        }
    }

    private func makeEngine(callID: UUID, isCaller: Bool, turn: CallTURN) throws -> VoiceCallEngine {
        try VoiceCallEngine(callID: callID, isCaller: isCaller, turn: turn) { [weak self] signal in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.messaging.sendCallSignal(signal, in: self.id)
                } catch {
                    self.status = "Call signaling unavailable"
                    self.stop(sendHangup: false)
                }
            }
        }
    }

    private func observe(_ call: VoiceCallEngine) {
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self, weak call] in
            while !Task.isCancelled {
                guard let self, let call else { return }
                self.state = call.state
                if call.state == .connected { self.status = "Encrypted call connected" }
                if call.state == .failed { self.status = "Encrypted call failed" }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func stop(sendHangup: Bool = true) {
        engine?.stop(sendHangup: sendHangup)
        engine = nil
        callID = nil
        stateTask?.cancel()
        stateTask = nil
        state = .idle
        if sendHangup { status = "" }
    }

    func close() {
        if let lifecycleToken {
            NotificationCenter.default.removeObserver(lifecycleToken)
            self.lifecycleToken = nil
        }
        stop(sendHangup: false)
    }
}

