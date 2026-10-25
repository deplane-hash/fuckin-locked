import Foundation
import SwiftUI
import UIKit

@MainActor protocol VoiceCallSession: AnyObject {
    var state: VoiceCallState { get }
    func startOutgoing() async throws
    func receive(_ signal: CallSignal) async throws
    func stop(sendHangup: Bool)
}

struct VoiceCallControls: View {
    @ObservedObject var controller: VoiceCallCoordinator

    var body: some View {
        if controller.hasIncomingOffer {
            Button("Accept") { Task { await controller.acceptIncoming() } }
                .accessibilityLabel("Accept voice call")
            Button("Decline") { controller.stop() }
                .accessibilityLabel("Decline voice call")
        } else {
            Button {
                if controller.isActive { controller.stop() }
                else { Task { await controller.startOutgoing() } }
            } label: {
                Image(systemName: controller.isActive ? "phone.down.fill" : "phone")
            }
            .accessibilityLabel(controller.isActive ? "End voice call" : "Start voice call")
        }
    }
}

struct VoiceCallStatus: View {
    @ObservedObject var controller: VoiceCallCoordinator
    var body: some View {
        if !controller.status.isEmpty {
            Text(controller.status).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

@MainActor struct VoiceCallDependencies {
    var isActive: () -> Bool
    var isVerified: () throws -> Bool
    var turn: () async throws -> CallTURN
    var makeSession: (UUID, Bool, CallTURN, @escaping (CallSignal) -> Void) throws -> any VoiceCallSession
    var send: (CallSignal) async throws -> Void
}

@MainActor final class VoiceCallCoordinator: ObservableObject {
    @Published private(set) var state: VoiceCallState = .idle
    @Published private(set) var status = ""
    @Published private(set) var hasIncomingOffer = false
    private let id: UUID
    private let vault: LocalVault
    private let dependencies: VoiceCallDependencies
    private var engine: (any VoiceCallSession)?
    private var callID: UUID?
    private var pendingOffer: CallSignal?
    private var pendingOfferDate: Date?
    private var signals: [CallSignal] = []
    private var consumedMessages = Set<UUID>()
    private var stateTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var outgoing: [CallSignal] = []
    private var lockToken: UUID?
    private var epoch: UInt64 = 0
    private var closed = false

    convenience init(id: UUID, vault: LocalVault, gateway: Gateway, messaging: MessagingService) {
        self.init(id: id, vault: vault, dependencies: VoiceCallDependencies(
            isActive: { UIApplication.shared.applicationState == .active },
            isVerified: { try messaging.isPeerVerified(for: id) },
            turn: {
                try await gateway.login(deviceID: vault.deviceID)
                try await gateway.requireCallCapabilities()
                return try await gateway.callTURN()
            },
            makeSession: { try VoiceCallEngine(callID: $0, isCaller: $1, turn: $2, sendSignal: $3) },
            send: { try await messaging.sendCallSignal($0, in: id) }))
    }

    init(id: UUID, vault: LocalVault, dependencies: VoiceCallDependencies) {
        self.id = id
        self.vault = vault
        self.dependencies = dependencies
        // Synchronous for every vault lock, including capture and screenshots.
        lockToken = vault.observeChatLock { [weak self] in self?.stop(sendHangup: false) }
    }

    var isActive: Bool { callID != nil }

    private func authorized() -> Bool {
        !closed && dependencies.isActive() && vault.isUnlocked &&
        vault.unlockedChatID == id && (try? dependencies.isVerified()) == true
    }

    private func check(_ ticket: UInt64, generation: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == ticket, vault.chatGeneration == generation, authorized() else {
            throw VoiceCallError.unavailable
        }
    }

    func startOutgoing() async {
        guard callID == nil, authorized() else { return }
        callID = UUID()
        state = .starting
        await setup(isCaller: true)
    }

    func acceptIncoming() async {
        guard hasIncomingOffer else { return }
        guard let date = pendingOfferDate, fresh(date),
              let pendingOffer, (try? pendingOffer.validate()) != nil, authorized() else {
            stop(sendHangup: false)
            return
        }
        hasIncomingOffer = false
        state = .starting
        await setup(isCaller: false)
    }

    private func setup(isCaller: Bool) async {
        let ticket = epoch
        let generation = vault.chatGeneration
        guard let currentID = callID else { return }
        do {
            try check(ticket, generation: generation)
            let turn = try await dependencies.turn()
            try check(ticket, generation: generation)
            let call = try dependencies.makeSession(currentID, isCaller, turn) { [weak self] signal in
                guard let self, self.epoch == ticket, self.authorized() else { return }
                self.enqueue(signal, ticket: ticket, generation: generation)
            }
            engine = call
            if isCaller {
                try await call.startOutgoing()
            } else if let offer = pendingOffer {
                try await call.receive(offer)
            } else {
                throw VoiceCallError.unavailable
            }
            try check(ticket, generation: generation)
            pendingOffer = nil
            pendingOfferDate = nil
            status = isCaller ? "Calling…" : "Connecting…"
            observe(call, ticket: ticket, generation: generation)
            drainSignals()
        } catch {
            guard epoch == ticket else { return }
            fail(error is CancellationError ? "" : "Call unavailable")
        }
    }

    private func enqueue(_ signal: CallSignal, ticket: UInt64, generation: UInt64) {
        guard outgoing.count < 128 else { fail("Call unavailable"); return }
        outgoing.append(signal)
        guard sendTask == nil else { return }
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == ticket { self.sendTask = nil } }
            do {
                while !self.outgoing.isEmpty {
                    try self.check(ticket, generation: generation)
                    let next = self.outgoing.removeFirst()
                    try await self.dependencies.send(next)
                    try self.check(ticket, generation: generation)
                }
            } catch {
                if self.epoch == ticket { self.fail("Call signaling unavailable") }
            }
        }
    }

    private func fresh(_ date: Date) -> Bool {
        let age = Date().timeIntervalSince(date)
        return age >= -30 && age <= 300
    }

    func consume(_ records: [StoredMessage]) {
        guard authorized() else { stop(sendHangup: false); return }
        for record in records where !record.isOutgoing {
            guard let signal = record.callSignal, consumedMessages.insert(record.id).inserted else { continue }
            guard (try? signal.validate()) != nil else { continue }
            if signal.kind == "offer" {
                guard callID == nil, fresh(record.sentAt) else { continue }
                callID = signal.callID
                pendingOffer = signal
                pendingOfferDate = record.sentAt
                hasIncomingOffer = true
                state = .ringing
                status = "Incoming call"
                // No network setup, audio session or microphone until Accept.
            } else {
                guard signal.callID == callID else { continue }
                if signal.kind == "hangup" { stop(sendHangup: false); continue }
                guard signals.count < 128 else { fail("Call unavailable"); return }
                signals.append(signal)
            }
        }
        drainSignals()
    }

    private func drainSignals() {
        guard signalTask == nil, pendingOffer == nil, let call = engine else { return }
        let ticket = epoch
        let generation = vault.chatGeneration
        signalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == ticket { self.signalTask = nil } }
            do {
                while !self.signals.isEmpty {
                    try self.check(ticket, generation: generation)
                    let signal = self.signals.removeFirst()
                    try await call.receive(signal)
                    try self.check(ticket, generation: generation)
                }
            } catch {
                if self.epoch == ticket { self.fail("Call unavailable") }
            }
        }
    }

    private func observe(_ call: any VoiceCallSession, ticket: UInt64, generation: UInt64) {
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self, weak call] in
            while !Task.isCancelled {
                guard let self, let call else { return }
                do { try self.check(ticket, generation: generation) }
                catch { if self.epoch == ticket { self.stop(sendHangup: false) }; return }
                self.state = call.state
                if call.state == .connected { self.status = "Call connected" }
                if call.state == .failed { self.fail("Call failed"); return }
                if call.state == .ended { self.stop(sendHangup: false); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func fail(_ message: String) {
        stop(sendHangup: false)
        status = message
    }

    func stop(sendHangup: Bool = true) {
        let endedID = callID
        let maySend = sendHangup && authorized()
        epoch &+= 1
        engine?.stop(sendHangup: false)
        engine = nil
        callID = nil
        pendingOffer = nil
        pendingOfferDate = nil
        hasIncomingOffer = false
        signals.removeAll(keepingCapacity: false)
        stateTask?.cancel(); stateTask = nil
        signalTask?.cancel(); signalTask = nil
        sendTask?.cancel(); sendTask = nil
        outgoing.removeAll(keepingCapacity: false)
        state = .idle
        status = ""
        if maySend, let endedID {
            let ticket = epoch
            Task { @MainActor [weak self] in
                guard let self, self.epoch == ticket, self.authorized() else { return }
                try? await self.dependencies.send(CallSignal(callID: endedID, kind: "hangup", body: Data()))
            }
        }
    }

    func close() {
        stop(sendHangup: false)
        closed = true
        if let lockToken { vault.removeChatLockObserver(lockToken); self.lockToken = nil }
    }
}
