import Foundation
import CryptoKit
import CommonCrypto
import Security

struct StoredChat: Codable, Identifiable {
    var id: UUID
    var title: String
    var isGroup: Bool
    var salt: Data
    var wrappedKey: Data
    var ciphertext: Data
}

struct ChatPayload: Codable {
    var messages: [String] = []
    var signal: SignalState? = nil
}

struct StoredIndex: Codable {
    var chats: [StoredChat] = []
    var profileName: String = "You"
    var username: String = ""
    var deviceID: String = ""
    var userID: String = ""
}

struct VaultHeader: Codable {
    var salt: Data
    var wrappedKey: Data
    var encryptedIndex: Data
}

enum VaultError: Error {
    case invalidPassword
    case delayed(Int)
    case corrupt
    case passwordTooShort
}

struct DelayRecord: Codable {
    var failures: Int = 0
    var nextAllowed: Date = .distantPast
}

struct DelayLedger: Codable {
    var app = DelayRecord()
    var chats: [String: DelayRecord] = [:]
}

@MainActor final class LocalVault: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isUnlocked = false
    @Published private(set) var chats: [StoredChat] = []
    @Published private(set) var profileName = "You"
    @Published private(set) var username = ""
    @Published private(set) var deviceID = ""
    @Published private(set) var unlockedChatID: UUID?
    @Published private(set) var messages: [String] = []
    private var appKey: SymmetricKey?
    private var chatKey: SymmetricKey?
    private var chatPayload: ChatPayload?
    private var header: VaultHeader?
    private var index = StoredIndex()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let storageFolder: URL

    private var folder: URL { storageFolder }
    private var vaultURL: URL { folder.appendingPathComponent("vault.bin") }
    private var delayURL: URL { folder.appendingPathComponent("delay.bin") }

    init(directory: URL? = nil) {
        storageFolder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Private", isDirectory: true)
        isConfigured = FileManager.default.fileExists(atPath: vaultURL.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (folder as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
    }

    private func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultError.corrupt }
        return bytes
    }

    private func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        guard let input = password.data(using: .utf8) else { throw VaultError.invalidPassword }
        var output = Data(count: 32)
        let result = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        inputBytes.bindMemory(to: Int8.self).baseAddress, input.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard result == kCCSuccess else { throw VaultError.corrupt }
        return SymmetricKey(data: output)
    }

    private func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw VaultError.corrupt }
        return combined
    }

    private func open(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    private func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        // The enclosing directory is excluded before the atomic replacement.
        // Failure to set the per-file hint must not make the caller believe the write was rolled back.
        try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    private func loadDelay() throws -> DelayLedger {
        guard let data = try? Data(contentsOf: delayURL),
              let state = try? decoder.decode(DelayLedger.self, from: data) else {
            throw VaultError.corrupt
        }
        return state
    }

    private func saveDelay(_ ledger: DelayLedger) throws {
        try write(encoder.encode(ledger), to: delayURL)
    }

    private func allowed(_ record: DelayRecord) throws {
        let seconds = Int(ceil(record.nextAllowed.timeIntervalSinceNow))
        if seconds > 0 { throw VaultError.delayed(seconds) }
    }

    private func escalated(_ state: DelayRecord) -> DelayRecord {
        var state = state
        state.failures += 1
        let seconds = min(3600, 1 << min(max(state.failures - 1, 0), 12))
        state.nextAllowed = Date().addingTimeInterval(TimeInterval(seconds))
        return state
    }

    private func appAllowed() throws {
        try allowed(try loadDelay().app)
    }

    private func failedAppAttempt() throws {
        var ledger = try loadDelay()
        ledger.app = escalated(ledger.app)
        try saveDelay(ledger)
    }

    private func chatDelayID(_ id: UUID) throws -> String {
        guard let appKey else { throw VaultError.corrupt }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(id.uuidString.utf8), using: appKey)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    private func chatAllowed(_ id: UUID) throws {
        let ledger = try loadDelay()
        let key = try chatDelayID(id)
        try allowed(ledger.chats[key] ?? DelayRecord())
    }

    private func failedChatAttempt(_ id: UUID) throws {
        var ledger = try loadDelay()
        let key = try chatDelayID(id)
        ledger.chats[key] = escalated(ledger.chats[key] ?? DelayRecord())
        try saveDelay(ledger)
    }

    private func resetChatDelay(_ id: UUID) throws {
        var ledger = try loadDelay()
        ledger.chats[try chatDelayID(id)] = nil
        try saveDelay(ledger)
    }

    func createAppPassword(_ password: String) throws {
        guard !isConfigured else { throw VaultError.corrupt }
        guard password.count >= 12 else { throw VaultError.passwordTooShort }
        let raw = try random(32)
        let salt = try random(16)
        let key = SymmetricKey(data: raw)
        let wrappingKey = try derive(password, salt: salt)
        let record = VaultHeader(salt: salt, wrappedKey: try seal(raw, key: wrappingKey),
                                 encryptedIndex: try seal(encoder.encode(StoredIndex()), key: key))
        try saveDelay(DelayLedger())
        try write(encoder.encode(record), to: vaultURL)
        header = record
        appKey = key
        index = StoredIndex()
        isConfigured = true
        isUnlocked = true
    }

    func unlock(_ password: String) throws {
        try appAllowed()
        let record = try decoder.decode(VaultHeader.self, from: Data(contentsOf: vaultURL))
        do {
            let raw = try open(record.wrappedKey, key: derive(password, salt: record.salt))
            let key = SymmetricKey(data: raw)
            let decoded = try decoder.decode(StoredIndex.self, from: open(record.encryptedIndex, key: key))
            var ledger = try loadDelay()
            ledger.app = DelayRecord()
            try saveDelay(ledger)
            header = record
            appKey = key
            index = decoded
            chats = decoded.chats
            profileName = decoded.profileName
            username = decoded.username
            deviceID = decoded.deviceID
            isUnlocked = true
        } catch {
            try failedAppAttempt()
            throw VaultError.invalidPassword
        }
    }

    private func save(_ candidate: StoredIndex) throws {
        guard var record = header, let appKey else { throw VaultError.corrupt }
        record.encryptedIndex = try seal(encoder.encode(candidate), key: appKey)
        try write(encoder.encode(record), to: vaultURL)
        header = record
        index = candidate
        chats = candidate.chats
    }

    func changeAppPassword(old: String, new: String) throws {
        guard new.count >= 12 else { throw VaultError.passwordTooShort }
        try appAllowed()
        guard let record = header, appKey != nil else { throw VaultError.corrupt }
        let raw: Data
        do {
            raw = try open(record.wrappedKey, key: derive(old, salt: record.salt))
            _ = try open(record.encryptedIndex, key: SymmetricKey(data: raw))
        } catch {
            try failedAppAttempt()
            throw VaultError.invalidPassword
        }
        var ledger = try loadDelay()
        ledger.app = DelayRecord()
        try saveDelay(ledger)
        let salt = try random(16)
        let changed = VaultHeader(salt: salt, wrappedKey: try seal(raw, key: derive(new, salt: salt)),
                                  encryptedIndex: record.encryptedIndex)
        try write(encoder.encode(changed), to: vaultURL)
        header = changed
    }

    func createChat(title: String, isGroup: Bool, password: String) throws {
        guard isUnlocked, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.corrupt }
        guard password.count >= 12 else { throw VaultError.passwordTooShort }
        let raw = try random(32)
        let salt = try random(16)
        var candidate = index
        candidate.chats.append(StoredChat(id: UUID(), title: title, isGroup: isGroup, salt: salt,
            wrappedKey: try seal(raw, key: derive(password, salt: salt)),
            ciphertext: try seal(encoder.encode(ChatPayload()), key: SymmetricKey(data: raw))))
        try save(candidate)
    }

    func setProfile(name: String, username: String, userID: String, deviceID: String) throws {
        guard isUnlocked else { throw VaultError.corrupt }
        var candidate = index
        candidate.profileName = name
        candidate.username = username
        candidate.userID = userID
        candidate.deviceID = deviceID
        try save(candidate)
        self.profileName = name
        self.username = username
        self.deviceID = deviceID
    }

    func unlockChat(_ id: UUID, password: String) throws {
        lockChat()
        guard isUnlocked, let chat = index.chats.first(where: { $0.id == id }) else { throw VaultError.corrupt }
        try chatAllowed(id)
        let key: SymmetricKey
        let content: ChatPayload
        do {
            let raw = try open(chat.wrappedKey, key: derive(password, salt: chat.salt))
            key = SymmetricKey(data: raw)
            let plaintext = try open(chat.ciphertext, key: key)
            if let current = try? decoder.decode(ChatPayload.self, from: plaintext) {
                content = current
            } else {
                content = ChatPayload(messages: try decoder.decode([String].self, from: plaintext))
            }
        } catch {
            try failedChatAttempt(id)
            throw VaultError.invalidPassword
        }
        try resetChatDelay(id)
        chatKey = key
        chatPayload = content
        messages = content.messages
        unlockedChatID = id
    }

    func signalState(for id: UUID) throws -> SignalState? {
        guard isUnlocked, unlockedChatID == id, chatKey != nil else { throw VaultError.corrupt }
        return chatPayload?.signal
    }

    func saveSignalState(_ state: SignalState, for id: UUID) throws {
        guard isUnlocked, unlockedChatID == id, let chatKey,
              let position = index.chats.firstIndex(where: { $0.id == id }),
              var payload = chatPayload else { throw VaultError.corrupt }
        payload.signal = state
        var candidate = index
        candidate.chats[position].ciphertext = try seal(encoder.encode(payload), key: chatKey)
        try save(candidate)
        chatPayload = payload
    }

    func changeChatPassword(_ id: UUID, old: String, new: String) throws {
        guard new.count >= 12, let position = index.chats.firstIndex(where: { $0.id == id }) else {
            throw VaultError.passwordTooShort
        }
        let chat = index.chats[position]
        try chatAllowed(id)
        let raw: Data
        do {
            raw = try open(chat.wrappedKey, key: derive(old, salt: chat.salt))
        } catch {
            try failedChatAttempt(id)
            throw VaultError.invalidPassword
        }
        try resetChatDelay(id)
        let salt = try random(16)
        var candidate = index
        candidate.chats[position].salt = salt
        candidate.chats[position].wrappedKey = try seal(raw, key: derive(new, salt: salt))
        try save(candidate)
        lockChat()
    }

    func lockChat() {
        messages.removeAll(keepingCapacity: false)
        chatPayload = nil
        chatKey = nil
        unlockedChatID = nil
    }

    func lockApp() {
        lockChat()
        index = StoredIndex()
        chats.removeAll(keepingCapacity: false)
        profileName = "You"
        username = ""
        deviceID = ""
        appKey = nil
        header = nil
        isUnlocked = false
    }
}
