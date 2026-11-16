import Foundation
import Testing
@testable import HA_Voice

struct HA_VoiceTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen",
        state: "idle"
    )
    private let office = MediaPlayerTarget(
        entityID: "media_player.office",
        friendlyName: "Office",
        state: "idle"
    )
    private let bedroom = MediaPlayerTarget(
        entityID: "media_player.bedroom",
        friendlyName: "Bedroom",
        state: "idle"
    )
    private let garage = MediaPlayerTarget(
        entityID: "media_player.garage",
        friendlyName: "Garage",
        state: "idle"
    )

    @Test func normalizesServerURL() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("homeassistant.local:8123/")
        #expect(url.absoluteString == "https://homeassistant.local:8123")
    }

    @Test func validatesToken() {
        #expect(HomeAssistantClient.isValidToken("abc123"))
        #expect(!HomeAssistantClient.isValidToken("   "))
    }

    @Test func filtersMediaPlayersFromStates() throws {
        let json = """
        [
          {
            "entity_id": "light.kitchen",
            "state": "on",
            "attributes": { "friendly_name": "Kitchen Light" }
          },
          {
            "entity_id": "media_player.office",
            "state": "idle",
            "attributes": { "friendly_name": "Office Speaker" }
          },
          {
            "entity_id": "media_player.kitchen",
            "state": "playing",
            "attributes": { "friendly_name": "Kitchen Speaker" }
          }
        ]
        """.data(using: .utf8)!

        let players = try HomeAssistantClient.mediaPlayers(from: json)

        #expect(players.map(\.entityID) == ["media_player.kitchen", "media_player.office"])
        #expect(players.first?.friendlyName == "Kitchen Speaker")
    }

    @Test func discoversMediaPlayersAndTTSEnginesFromSingleStatesPayload() throws {
        let json = """
        [
          {
            "entity_id": "tts.piper",
            "state": "unknown",
            "attributes": { "friendly_name": "Piper" }
          },
          {
            "entity_id": "media_player.office",
            "state": "idle",
            "attributes": { "friendly_name": "Office Speaker" }
          },
          {
            "entity_id": "tts.home_assistant_cloud",
            "state": "unknown",
            "attributes": { "friendly_name": "Home Assistant Cloud" }
          },
          {
            "entity_id": "media_player.kitchen",
            "state": "playing",
            "attributes": { "friendly_name": "Kitchen Speaker" }
          }
        ]
        """.data(using: .utf8)!

        let discovered = try HomeAssistantClient.mediaPlayersAndEngines(from: json)

        #expect(discovered.mediaPlayers.map(\.entityID) == ["media_player.kitchen", "media_player.office"])
        #expect(discovered.ttsEngines == [
            TTSEngine(entityID: "tts.piper", name: "Piper"),
            TTSEngine(entityID: "tts.home_assistant_cloud", name: "Home Assistant Cloud")
        ])

        let defaultWithCloud = HomeAssistantClient.defaultEngine(from: discovered.ttsEngines)
        #expect(defaultWithCloud?.entityID == "tts.home_assistant_cloud")

        let withoutCloud = discovered.ttsEngines.filter { $0.entityID != "tts.home_assistant_cloud" }
        let defaultWithoutCloud = HomeAssistantClient.defaultEngine(from: withoutCloud)
        #expect(defaultWithoutCloud?.entityID == "tts.piper")
    }

    @Test func buildsCloudSayPayloadWithVoice() throws {
        let voice = VoicePreset(id: UUID(), name: "Guy", language: "en-US", voice: "GuyNeural", isCustom: true)
        let payload = HomeAssistantClient.ttsPayload(message: "Time to go", target: kitchen, voicePreset: voice)

        #expect(payload["entity_id"] as? String == "media_player.kitchen")
        #expect(payload["message"] as? String == "Time to go")
        #expect(payload["cache"] as? Bool == false)
        #expect(payload["language"] as? String == "en-US")
        let options = try #require(payload["options"] as? [String: String])
        #expect(options["voice"] == "GuyNeural")
    }

    @Test func buildsCloudSayPayloadWithoutVoice() {
        let payload = HomeAssistantClient.ttsPayload(
            message: "Hello",
            target: kitchen,
            voicePreset: .defaultPreset
        )

        #expect(payload["options"] == nil)
        #expect(payload["language"] as? String == "en-US")
    }

    @Test func buildsSpeakPayloadSingleAndMultipleSpeakersWithAndWithoutVoiceAndLanguage() throws {
        let engines = [
            TTSEngine(entityID: "tts.google_translate", name: "Google Translate"),
            TTSEngine(entityID: "tts.home_assistant_cloud", name: "Home Assistant Cloud"),
            TTSEngine(entityID: "tts.piper", name: "Piper")
        ]

        // 1. Single speaker, server default engine (prefers Cloud), no voice, with language
        let defaultPayload = try HomeAssistantClient.speakPayload(
            message: "Hello Kitchen",
            targets: [kitchen],
            voicePreset: .defaultPreset,
            ttsEngines: engines
        )
        #expect(defaultPayload["entity_id"] as? String == "tts.home_assistant_cloud")
        #expect(defaultPayload["media_player_entity_id"] as? [String] == ["media_player.kitchen"])
        #expect(defaultPayload["message"] as? String == "Hello Kitchen")
        #expect(defaultPayload["language"] as? String == "en-US")
        #expect(defaultPayload["cache"] as? Bool == false)
        #expect(defaultPayload["options"] == nil)

        // 2. Multiple speakers, explicit engine, with voice and language
        let piperVoice = VoicePreset(
            id: UUID(),
            name: "Piper Lessac",
            language: "en-US",
            voice: "en_US-lessac-medium",
            isCustom: true,
            engineID: "tts.piper"
        )
        let multiPayload = try HomeAssistantClient.speakPayload(
            message: "Dinner is ready",
            targets: [kitchen, office, bedroom],
            voicePreset: piperVoice,
            ttsEngines: engines
        )
        #expect(multiPayload["entity_id"] as? String == "tts.piper")
        #expect(multiPayload["media_player_entity_id"] as? [String] == [
            "media_player.kitchen",
            "media_player.office",
            "media_player.bedroom"
        ])
        #expect(multiPayload["message"] as? String == "Dinner is ready")
        #expect(multiPayload["language"] as? String == "en-US")
        #expect(multiPayload["cache"] as? Bool == false)
        let options = try #require(multiPayload["options"] as? [String: String])
        #expect(options["voice"] == "en_US-lessac-medium")

        // 3. Server default when Cloud is absent, empty language and empty voice omitted
        let localEngines = [
            TTSEngine(entityID: "tts.piper", name: "Piper"),
            TTSEngine(entityID: "tts.google_translate", name: "Google Translate")
        ]
        let minimalPreset = VoicePreset(
            id: UUID(),
            name: "Minimal",
            language: "   ",
            voice: "   ",
            isCustom: true,
            engineID: nil
        )
        let minimalPayload = try HomeAssistantClient.speakPayload(
            message: "Quick check",
            targets: [kitchen, office],
            voicePreset: minimalPreset,
            ttsEngines: localEngines
        )
        #expect(minimalPayload["entity_id"] as? String == "tts.piper")
        #expect(minimalPayload["media_player_entity_id"] as? [String] == ["media_player.kitchen", "media_player.office"])
        #expect(minimalPayload["language"] == nil)
        #expect(minimalPayload["options"] == nil)
        #expect(minimalPayload["cache"] as? Bool == false)
    }

    @Test func builtInVoicesConfigureEngineIDsCorrectly() throws {
        #expect(VoicePreset.defaultPreset.engineID == nil)

        for name in ["Jenny", "Guy", "Aria", "Maisie"] {
            let preset = try #require(VoicePreset.builtIns.first { $0.name == name })
            #expect(preset.engineID == "tts.home_assistant_cloud")
            #expect(!preset.isCustom)
        }

        let maisie = try #require(VoicePreset.builtIns.first { $0.name == "Maisie" })
        #expect(maisie.language == "en-GB")
        #expect(maisie.voice == "MaisieNeural")
    }

    @Test func targetFormattingForComposerChipAndHistoryBubble() {
        #expect(ComposerView.targetChipText(for: [kitchen]) == "Kitchen")
        #expect(ComposerView.targetChipText(for: [kitchen, office, bedroom]) == "Kitchen + 2")

        #expect(MessageRecord.targetsSummary([kitchen]) == "Kitchen")
        #expect(MessageRecord.targetsSummary([kitchen, office]) == "Kitchen, Office")
        #expect(MessageRecord.targetsSummary([kitchen, office, bedroom]) == "Kitchen, Office, Bedroom")
        #expect(MessageRecord.targetsSummary([kitchen, office, bedroom, garage]) == "Kitchen, Office, Bedroom +1")
    }

    @Test func repeatLimitCompletionRules() {
        #expect(RepeatLimit.count(3).isComplete(sentCount: 3, elapsed: 0))
        #expect(!RepeatLimit.count(3).isComplete(sentCount: 2, elapsed: 100))
        #expect(RepeatLimit.duration(60).isComplete(sentCount: 1, elapsed: 60))
        #expect(!RepeatLimit.duration(60).isComplete(sentCount: 100, elapsed: 59))
        #expect(!RepeatLimit.indefinitely.isComplete(sentCount: 100, elapsed: 10_000))
    }

    @Test func countdownMessageReplacesMinutesToken() {
        let message = AppState.countdownMessage(
            template: "You have {minutes} minutes until it's time to go.",
            remaining: 9.1 * 60
        )

        #expect(message == "You have 10 minutes until it's time to go.")
    }

    @Test func onceAsMessagePrependsSenderName() {
        let message = AppState.messageWithSenderName("Time to leave", senderName: "Waverly")

        #expect(message == "Waverly says: Time to leave")
    }

    @Test func qrTokenParserAcceptsRawToken() {
        let validJWT = "header123.payload456.signature789"
        #expect(QRTokenParser.token(from: "  \(validJWT)  ") == validJWT)
        #expect(QRTokenParser.token(from: "  raw-token-value  ") == nil)
    }

    @Test func qrTokenParserExtractsJSONToken() {
        let rawValue = #"{"long_lived_access_token":"json-token"}"#

        #expect(QRTokenParser.token(from: rawValue) == "json-token")
    }

    @Test func qrTokenParserExtractsURLToken() {
        let rawValue = "homeassistant://token?access_token=url-token"

        #expect(QRTokenParser.token(from: rawValue) == "url-token")
    }
}
