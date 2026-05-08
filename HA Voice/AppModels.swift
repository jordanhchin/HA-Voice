import Foundation

struct ServerProfile: Codable, Equatable {
    var serverURL: String = ""
    var displayName: String = "Home Assistant"
    var lastConnectionStatus: ConnectionStatus = .notTested
}

enum ConnectionStatus: String, Codable, Equatable {
    case notTested
    case connected
    case failed
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

struct VoicePreset: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var language: String
    var voice: String
    var isCustom: Bool

    var serviceVoice: String? {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let defaultPreset = VoicePreset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Default Home Assistant voice",
        language: "en-US",
        voice: "",
        isCustom: false
    )

    static let builtIns: [VoicePreset] = [
        .defaultPreset,
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Jenny",
            language: "en-US",
            voice: "JennyNeural",
            isCustom: false
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Guy",
            language: "en-US",
            voice: "GuyNeural",
            isCustom: false
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Aria",
            language: "en-US",
            voice: "AriaNeural",
            isCustom: false
        ),
        VoicePreset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Maisie",
            language: "en-GB",
            voice: "MaisieNeural",
            isCustom: false
        )
    ]
}

enum MessageStatus: String, Codable, Equatable {
    case sending
    case sent
    case failed
    case cancelled
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
    var target: MediaPlayerTarget
    var voicePreset: VoicePreset
    var sentAt: Date
    var status: MessageStatus
    var errorMessage: String?
    var kind: MessageKind
    var detail: String?
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
}

struct RepeatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var message: String
    var target: MediaPlayerTarget
    var voicePreset: VoicePreset
    var interval: TimeInterval
    var limit: RepeatLimit
    var startedAt: Date
    var sentCount: Int
    var status: SessionStatus

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
    var target: MediaPlayerTarget
    var voicePreset: VoicePreset
    var template: String
    var finalMessage: String
    var startedAt: Date
    var remaining: TimeInterval
    var status: SessionStatus

    var summary: String {
        "\(Int(ceil(max(remaining, 0) / 60))) min remaining"
    }
}

enum ComposerMode: String, CaseIterable, Identifiable {
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

struct PersistedAppState: Codable {
    var serverProfile: ServerProfile
    var senderName: String
    var selectedTargetID: String?
    var selectedVoiceID: UUID
    var mediaPlayers: [MediaPlayerTarget]
    var voicePresets: [VoicePreset]
    var messages: [MessageRecord]

    enum CodingKeys: String, CodingKey {
        case serverProfile
        case senderName
        case selectedTargetID
        case selectedVoiceID
        case mediaPlayers
        case voicePresets
        case messages
    }

    init(
        serverProfile: ServerProfile,
        senderName: String,
        selectedTargetID: String?,
        selectedVoiceID: UUID,
        mediaPlayers: [MediaPlayerTarget],
        voicePresets: [VoicePreset],
        messages: [MessageRecord]
    ) {
        self.serverProfile = serverProfile
        self.senderName = senderName
        self.selectedTargetID = selectedTargetID
        self.selectedVoiceID = selectedVoiceID
        self.mediaPlayers = mediaPlayers
        self.voicePresets = voicePresets
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverProfile = try container.decode(ServerProfile.self, forKey: .serverProfile)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        selectedTargetID = try container.decodeIfPresent(String.self, forKey: .selectedTargetID)
        selectedVoiceID = try container.decode(UUID.self, forKey: .selectedVoiceID)
        mediaPlayers = try container.decode([MediaPlayerTarget].self, forKey: .mediaPlayers)
        voicePresets = try container.decode([VoicePreset].self, forKey: .voicePresets)
        messages = try container.decode([MessageRecord].self, forKey: .messages)
    }
}
