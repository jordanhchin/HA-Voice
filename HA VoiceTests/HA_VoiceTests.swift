import Foundation
import Testing
@testable import HA_Voice

struct HA_VoiceTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen",
        state: "idle"
    )

    @Test func normalizesServerURL() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("homeassistant.local:8123/")
        #expect(url.absoluteString == "http://homeassistant.local:8123")
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

    @Test func builtInVoicesIncludeMaisie() throws {
        let maisie = try #require(VoicePreset.builtIns.first { $0.name == "Maisie" })

        #expect(maisie.language == "en-GB")
        #expect(maisie.voice == "MaisieNeural")
        #expect(!maisie.isCustom)
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
        #expect(QRTokenParser.token(from: "  raw-token-value  ") == "raw-token-value")
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
