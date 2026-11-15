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
    case expired
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
    var target: MediaPlayerTarget
    var voicePreset: VoicePreset
    var template: String
    var finalMessage: String
    var startedAt: Date
    var remaining: TimeInterval
    var status: SessionStatus
    var inFlightMessageID: UUID? = nil

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
        serverProfile = (try? container.decode(ServerProfile.self, forKey: .serverProfile)) ?? ServerProfile()
        senderName = (try? container.decodeIfPresent(String.self, forKey: .senderName)) ?? ""
        selectedTargetID = try? container.decodeIfPresent(String.self, forKey: .selectedTargetID)
        selectedVoiceID = (try? container.decodeIfPresent(UUID.self, forKey: .selectedVoiceID)) ?? VoicePreset.defaultPreset.id

        if let failablePlayers = try? container.decode([FailableDecodable<MediaPlayerTarget>].self, forKey: .mediaPlayers) {
            mediaPlayers = failablePlayers.compactMap(\.value)
        } else {
            mediaPlayers = []
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
    var target: MediaPlayerTarget
    var voicePreset: VoicePreset
    var sentAt: Date
    var status: MessageStatus
    var errorMessage: String?
    var kind: MessageKind
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id, text, target, voicePreset, sentAt, status, errorMessage, kind, detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        target = try container.decode(MediaPlayerTarget.self, forKey: .target)
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
            target: target,
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
