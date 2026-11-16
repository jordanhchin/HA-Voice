import Foundation
import OSLog

struct ServerProfile: Codable, Equatable {
    var serverURL: String = ""
    var displayName: String = "Home Assistant"
    var lastConnectionStatus: ConnectionStatus = .notTested

    enum CodingKeys: String, CodingKey {
        case serverURL
        case displayName
        case lastConnectionStatus
    }

    init(
        serverURL: String = "",
        displayName: String = "Home Assistant",
        lastConnectionStatus: ConnectionStatus = .notTested
    ) {
        self.serverURL = serverURL
        self.displayName = displayName
        self.lastConnectionStatus = lastConnectionStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Home Assistant"
        if let raw = try? container.decodeIfPresent(String.self, forKey: .lastConnectionStatus) {
            lastConnectionStatus = ConnectionStatus(rawValue: raw) ?? .notTested
        } else {
            lastConnectionStatus = .notTested
        }
    }
}

enum ConnectionStatus: String, Codable, Equatable {
    case notTested
    case connected
    case failed

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode(String.self)
        self = raw.flatMap(ConnectionStatus.init(rawValue:)) ?? .notTested
    }
}

struct MediaPlayerTarget: Identifiable, Codable, Equatable, Hashable {
    var id: String { entityID }

    let entityID: String
    let friendlyName: String
    let state: String

    var displayName: String {
        friendlyName.isEmpty ? entityID : friendlyName
    }
}

struct TTSEngine: Identifiable, Codable, Equatable, Hashable {
    var id: String { entityID }

    let entityID: String
    let name: String

    init(entityID: String, name: String = "") {
        self.entityID = entityID
        self.name = name.isEmpty ? entityID : name
    }

    var displayName: String {
        name.isEmpty ? entityID : name
    }
}

struct VoicePreset: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var language: String
    var voice: String
    var isCustom: Bool
    var engineID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case language
        case voice
        case isCustom
        case engineID
    }

    init(
        id: UUID,
        name: String,
        language: String,
        voice: String,
        isCustom: Bool,
        engineID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.voice = voice
        self.isCustom = isCustom
        self.engineID = engineID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        language = try container.decode(String.self, forKey: .language)
        voice = try container.decode(String.self, forKey: .voice)
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        engineID = try container.decodeIfPresent(String.self, forKey: .engineID)
    }

    var serviceVoice: String? {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let cloudEngineID = "tts.home_assistant_cloud"

    static let defaultPreset = VoicePreset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Default Home Assistant voice",
        language: "en-US",
        voice: "",
        isCustom: false,
        engineID: nil
    )

    static let builtIns: [VoicePreset] = [
        .defaultPreset,
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Jenny",
            language: "en-US",
            voice: "JennyNeural",
            isCustom: false,
            engineID: cloudEngineID
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Guy",
            language: "en-US",
            voice: "GuyNeural",
            isCustom: false,
            engineID: cloudEngineID
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Aria",
            language: "en-US",
            voice: "AriaNeural",
            isCustom: false,
            engineID: cloudEngineID
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Maisie",
            language: "en-GB",
            voice: "MaisieNeural",
            isCustom: false,
            engineID: cloudEngineID
        )
    ]
}

enum MessageStatus: String, Codable, Equatable {
    case sending
    case sent
    case failed
    case cancelled
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode(String.self)
        self = raw.flatMap(MessageStatus.init(rawValue:)) ?? .unknown
    }
}

enum MessageKind: String, Codable, Equatable {
    case single
    case singleAs
    case repeated
    case countdown
}

struct MessageRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var targets: [MediaPlayerTarget]
    var voicePreset: VoicePreset
    var sentAt: Date
    var status: MessageStatus
    var errorMessage: String?
    var kind: MessageKind
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case targets
        case target
        case voicePreset
        case sentAt
        case status
        case errorMessage
        case kind
        case detail
    }

    init(
        id: UUID,
        text: String,
        targets: [MediaPlayerTarget],
        voicePreset: VoicePreset,
        sentAt: Date,
        status: MessageStatus,
        errorMessage: String?,
        kind: MessageKind,
        detail: String?
    ) {
        self.id = id
        self.text = text
        self.targets = targets
        self.voicePreset = voicePreset
        self.sentAt = sentAt
        self.status = status
        self.errorMessage = errorMessage
        self.kind = kind
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        if container.contains(.targets) {
            targets = try container.decode([MediaPlayerTarget].self, forKey: .targets)
        } else {
            let singleTarget = try container.decode(MediaPlayerTarget.self, forKey: .target)
            targets = [singleTarget]
        }
        voicePreset = try container.decode(VoicePreset.self, forKey: .voicePreset)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        status = try container.decode(MessageStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        kind = try container.decode(MessageKind.self, forKey: .kind)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(targets, forKey: .targets)
        try container.encode(voicePreset, forKey: .voicePreset)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    var targetsDisplayName: String {
        Self.targetsSummary(targets)
    }

    static func targetsSummary(_ targets: [MediaPlayerTarget]) -> String {
        let names = targets.map(\.displayName)
        guard names.count > 3 else {
            return names.joined(separator: ", ")
        }
        let prefix = names.prefix(3).joined(separator: ", ")
        return "\(prefix) +\(names.count - 3)"
    }
}

enum RepeatLimit: Codable, Equatable {
    case count(Int)
    case duration(TimeInterval)
    case indefinitely

    func isComplete(sentCount: Int, elapsed: TimeInterval) -> Bool {
        switch self {
        case .count(let count):
            sentCount >= count
        case .duration(let duration):
            elapsed >= duration
        case .indefinitely:
            false
        }
    }
}

enum SessionStatus: String, Codable, Equatable {
    case running
    case stopped
    case completed
    case pausedBySystem
    case failed
    case expired

    var isResumable: Bool {
        self == .pausedBySystem || self == .failed
    }

    var isActive: Bool {
        self == .running || isResumable
    }
}

struct RepeatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var message: String
    var targets: [MediaPlayerTarget]
    var voicePreset: VoicePreset
    var interval: TimeInterval
    var limit: RepeatLimit
    var startedAt: Date
    var sentCount: Int
    var status: SessionStatus
    var inFlightMessageID: UUID? = nil

    var summary: String {
        switch limit {
        case .count(let count):
            "Repeating \(sentCount)/\(count)"
        case .duration(let duration):
            "Repeating for \(Int(duration / 60)) min"
        case .indefinitely:
            "Repeating until stopped"
        }
    }
}

struct CountdownSession: Identifiable, Codable, Equatable {
    let id: UUID
    var totalDuration: TimeInterval
    var interval: TimeInterval
    var targets: [MediaPlayerTarget]
    var voicePreset: VoicePreset
    var template: String
    var finalMessage: String
    var startedAt: Date
    var remaining: TimeInterval
    var status: SessionStatus
    var inFlightMessageID: UUID? = nil
    /// Interval announcements already made (or attempted and possibly delivered); the next is due at startedAt + announcedCount * interval.
    var announcedCount = 0

    var summary: String {
        "\(Int(ceil(max(remaining, 0) / 60))) min remaining"
    }
}

enum ComposerMode: String, CaseIterable, Identifiable, Codable {
    case once
    case onceAs
    case repeatCount
    case repeatDuration
    case repeatIndefinitely
    case countdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: "Once"
        case .onceAs: "Once As"
        case .repeatCount: "Count"
        case .repeatDuration: "Duration"
        case .repeatIndefinitely: "Until Stopped"
        case .countdown: "Countdown"
        }
    }

    var iconName: String {
        switch self {
        case .once: "paperplane"
        case .onceAs: "person.wave.2"
        case .repeatCount: "number"
        case .repeatDuration: "clock"
        case .repeatIndefinitely: "infinity"
        case .countdown: "timer"
        }
    }
}

struct ComposerDraft: Codable, Equatable {
    static let defaultCountdownTemplate = "You have {minutes} minutes until it's time to go."
    static let defaultFinalMessage = "It's time to go."

    var message: String
    var mode: ComposerMode
    var repeatCount: Int
    var repeatDurationMinutes: Int
    var repeatIntervalSeconds: Int
    var countdownMinutes: Int
    var countdownIntervalMinutes: Int
    var countdownTemplate: String
    var finalMessage: String

    init(
        message: String = "",
        mode: ComposerMode = .once,
        repeatCount: Int = 3,
        repeatDurationMinutes: Int = 5,
        repeatIntervalSeconds: Int = 60,
        countdownMinutes: Int = 10,
        countdownIntervalMinutes: Int = 1,
        countdownTemplate: String = ComposerDraft.defaultCountdownTemplate,
        finalMessage: String = ComposerDraft.defaultFinalMessage
    ) {
        self.message = message
        self.mode = mode
        self.repeatCount = repeatCount
        self.repeatDurationMinutes = repeatDurationMinutes
        self.repeatIntervalSeconds = repeatIntervalSeconds
        self.countdownMinutes = countdownMinutes
        self.countdownIntervalMinutes = countdownIntervalMinutes
        self.countdownTemplate = countdownTemplate
        self.finalMessage = finalMessage
    }
}

struct PersistedAppState: Codable {
    var serverProfile: ServerProfile
    var senderName: String
    var selectedTargetIDs: [String]
    var selectedVoiceID: UUID
    var mediaPlayers: [MediaPlayerTarget]
    var ttsEngines: [TTSEngine]
    var voicePresets: [VoicePreset]
    var messages: [MessageRecord]

    enum CodingKeys: String, CodingKey {
        case serverProfile
        case senderName
        case selectedTargetIDs
        case selectedTargetID
        case selectedVoiceID
        case mediaPlayers
        case ttsEngines
        case voicePresets
        case messages
    }

    init(
        serverProfile: ServerProfile,
        senderName: String,
        selectedTargetIDs: [String],
        selectedVoiceID: UUID,
        mediaPlayers: [MediaPlayerTarget],
        ttsEngines: [TTSEngine] = [],
        voicePresets: [VoicePreset],
        messages: [MessageRecord]
    ) {
        self.serverProfile = serverProfile
        self.senderName = senderName
        self.selectedTargetIDs = Self.uniqueTargetIDs(selectedTargetIDs)
        self.selectedVoiceID = selectedVoiceID
        self.mediaPlayers = mediaPlayers
        self.ttsEngines = ttsEngines
        self.voicePresets = voicePresets
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverProfile = (try? container.decode(ServerProfile.self, forKey: .serverProfile)) ?? ServerProfile()
        senderName = (try? container.decodeIfPresent(String.self, forKey: .senderName)) ?? ""
        if let ids = try? container.decodeIfPresent([String].self, forKey: .selectedTargetIDs) {
            selectedTargetIDs = Self.uniqueTargetIDs(ids)
        } else if let legacyID = try? container.decodeIfPresent(String.self, forKey: .selectedTargetID) {
            selectedTargetIDs = Self.uniqueTargetIDs([legacyID])
        } else {
            selectedTargetIDs = []
        }
        selectedVoiceID = (try? container.decodeIfPresent(UUID.self, forKey: .selectedVoiceID)) ?? VoicePreset.defaultPreset.id

        if let failablePlayers = try? container.decode([FailableDecodable<MediaPlayerTarget>].self, forKey: .mediaPlayers) {
            mediaPlayers = failablePlayers.compactMap(\.value)
        } else {
            mediaPlayers = []
        }

        if let failableEngines = try? container.decode([FailableDecodable<TTSEngine>].self, forKey: .ttsEngines) {
            ttsEngines = failableEngines.compactMap(\.value)
        } else {
            ttsEngines = []
        }

        if let failablePresets = try? container.decode([FailableDecodable<VoicePreset>].self, forKey: .voicePresets) {
            let presets = failablePresets.compactMap(\.value)
            voicePresets = presets.isEmpty ? VoicePreset.builtIns : presets
        } else {
            voicePresets = VoicePreset.builtIns
        }

        if let failableMessages = try? container.decode([FailableDecodable<LenientMessageRecord>].self, forKey: .messages) {
            messages = failableMessages.compactMap { $0.value?.record }
        } else {
            messages = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverProfile, forKey: .serverProfile)
        try container.encode(senderName, forKey: .senderName)
        try container.encode(Self.uniqueTargetIDs(selectedTargetIDs), forKey: .selectedTargetIDs)
        try container.encode(selectedVoiceID, forKey: .selectedVoiceID)
        try container.encode(mediaPlayers, forKey: .mediaPlayers)
        try container.encode(ttsEngines, forKey: .ttsEngines)
        try container.encode(voicePresets, forKey: .voicePresets)
        try container.encode(messages, forKey: .messages)
    }

    static func uniqueTargetIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            self.value = try container.decode(T.self)
        } catch {
            Logger.persistence.error("Dropped corrupt record from persistence: \(error.localizedDescription, privacy: .public)")
            self.value = nil
        }
    }
}

private struct LenientMessageRecord: Decodable {
    let id: UUID
    var text: String
    var targets: [MediaPlayerTarget]
    var voicePreset: VoicePreset
    var sentAt: Date
    var status: MessageStatus
    var errorMessage: String?
    var kind: MessageKind
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id, text, targets, target, voicePreset, sentAt, status, errorMessage, kind, detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        if container.contains(.targets) {
            targets = try container.decode([MediaPlayerTarget].self, forKey: .targets)
        } else {
            let singleTarget = try container.decode(MediaPlayerTarget.self, forKey: .target)
            targets = [singleTarget]
        }
        voicePreset = try container.decode(VoicePreset.self, forKey: .voicePreset)
        sentAt = try container.decode(Date.self, forKey: .sentAt)

        if let statusRaw = try? container.decodeIfPresent(String.self, forKey: .status) {
            status = MessageStatus(rawValue: statusRaw) ?? .unknown
        } else {
            status = .unknown
        }

        errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)

        if let kindRaw = try? container.decodeIfPresent(String.self, forKey: .kind) {
            kind = MessageKind(rawValue: kindRaw) ?? .single
        } else {
            kind = .single
        }

        detail = try? container.decodeIfPresent(String.self, forKey: .detail)
    }

    var record: MessageRecord {
        MessageRecord(
            id: id,
            text: text,
            targets: targets,
            voicePreset: voicePreset,
            sentAt: sentAt,
            status: status,
            errorMessage: errorMessage,
            kind: kind,
            detail: detail
        )
    }
}

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "WaverlyWorks.HA-Voice"
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
