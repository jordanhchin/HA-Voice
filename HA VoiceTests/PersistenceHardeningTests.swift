import Foundation
import Testing
@testable import HA_Voice

struct PersistenceHardeningTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen",
        state: "idle"
    )

    @Test func roundTripAppState() throws {
        let voice = VoicePreset(
            id: UUID(),
            name: "Custom Voice",
            language: "en-US",
            voice: "CustomNeural",
            isCustom: true
        )
        let record = MessageRecord(
            id: UUID(),
            text: "Dinner is ready",
            target: kitchen,
            voicePreset: voice,
            sentAt: Date(timeIntervalSince1970: 1700000000),
            status: .sent,
            errorMessage: nil,
            kind: .single,
            detail: nil
        )
        let original = PersistedAppState(
            serverProfile: ServerProfile(
                serverURL: "https://homeassistant.local:8123",
                displayName: "Home Server",
                lastConnectionStatus: .connected
            ),
            senderName: "Alice",
            selectedTargetID: kitchen.entityID,
            selectedVoiceID: voice.id,
            mediaPlayers: [kitchen],
            voicePresets: [voice],
            messages: [record]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedAppState.self, from: data)

        #expect(decoded.serverProfile.serverURL == "https://homeassistant.local:8123")
        #expect(decoded.serverProfile.displayName == "Home Server")
        #expect(decoded.serverProfile.lastConnectionStatus == .connected)
        #expect(decoded.senderName == "Alice")
        #expect(decoded.selectedTargetID == kitchen.entityID)
        #expect(decoded.selectedVoiceID == voice.id)
        #expect(decoded.mediaPlayers.count == 1)
        #expect(decoded.mediaPlayers.first?.entityID == kitchen.entityID)
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages.first?.text == "Dinner is ready")
        #expect(decoded.messages.first?.status == .sent)
        #expect(decoded.messages.first?.kind == .single)
    }

    @Test func legacyJSONDecodesWithDefaults() throws {
        let legacyJSON = """
        {
            "serverProfile": {
                "serverURL": "https://ha.internal:8123"
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersistedAppState.self, from: legacyJSON)

        #expect(decoded.serverProfile.serverURL == "https://ha.internal:8123")
        #expect(decoded.serverProfile.displayName == "Home Assistant")
        #expect(decoded.serverProfile.lastConnectionStatus == .notTested)
        #expect(decoded.senderName == "")
        #expect(decoded.selectedTargetID == nil)
        #expect(decoded.selectedVoiceID == VoicePreset.defaultPreset.id)
        #expect(decoded.mediaPlayers.isEmpty)
        #expect(decoded.voicePresets == VoicePreset.builtIns)
        #expect(decoded.messages.isEmpty)
    }

    @Test func dropsCorruptMessageWhilePreservingValidMessages() throws {
        let json = """
        {
            "serverProfile": {
                "serverURL": "https://ha.local:8123"
            },
            "messages": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "text": "First valid message",
                    "target": {
                        "entityID": "media_player.kitchen",
                        "friendlyName": "Kitchen",
                        "state": "idle"
                    },
                    "voicePreset": {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "name": "Default",
                        "language": "en-US",
                        "voice": "",
                        "isCustom": false
                    },
                    "sentAt": 1700000000,
                    "status": "sent",
                    "kind": "single"
                },
                {
                    "id": "not-a-valid-uuid",
                    "text": "Corrupted record"
                },
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "text": "Second valid message",
                    "target": {
                        "entityID": "media_player.kitchen",
                        "friendlyName": "Kitchen",
                        "state": "idle"
                    },
                    "voicePreset": {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "name": "Default",
                        "language": "en-US",
                        "voice": "",
                        "isCustom": false
                    },
                    "sentAt": 1700000010,
                    "status": "sent",
                    "kind": "single"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(PersistedAppState.self, from: json)

        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0].text == "First valid message")
        #expect(decoded.messages[1].text == "Second valid message")
    }

    @Test func unknownEnumsFallbackGracefully() throws {
        let json = """
        {
            "serverProfile": {
                "serverURL": "https://ha.local:8123",
                "lastConnectionStatus": "futureUnknownStatus"
            },
            "messages": [
                {
                    "id": "33333333-3333-3333-3333-333333333333",
                    "text": "Status test",
                    "target": {
                        "entityID": "media_player.kitchen",
                        "friendlyName": "Kitchen",
                        "state": "idle"
                    },
                    "voicePreset": {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "name": "Default",
                        "language": "en-US",
                        "voice": "",
                        "isCustom": false
                    },
                    "sentAt": 1700000000,
                    "status": "futureUnknownStatus",
                    "kind": "futureUnknownKind"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(PersistedAppState.self, from: json)

        #expect(decoded.serverProfile.lastConnectionStatus == .notTested)
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].status == .unknown)
        #expect(decoded.messages[0].kind == .single)
    }

    @Test func messageStatusDecodesUnknownValuesToUnknown() throws {
        let known = try JSONDecoder().decode(MessageStatus.self, from: "\"sent\"".data(using: .utf8)!)
        #expect(known == .sent)

        let unknown = try JSONDecoder().decode(MessageStatus.self, from: "\"futureUnrecognizedStatus\"".data(using: .utf8)!)
        #expect(unknown == .unknown)
    }

    @Test func dropsCorruptMediaPlayerTargetWhilePreservingValidTargets() throws {
        let json = """
        {
            "mediaPlayers": [
                {
                    "entityID": "media_player.kitchen",
                    "friendlyName": "Kitchen",
                    "state": "idle"
                },
                {
                    "bad_field": 123
                },
                {
                    "entityID": "media_player.living_room",
                    "friendlyName": "Living Room",
                    "state": "playing"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersistedAppState.self, from: json)

        #expect(decoded.mediaPlayers.count == 2)
        #expect(decoded.mediaPlayers[0].entityID == "media_player.kitchen")
        #expect(decoded.mediaPlayers[1].entityID == "media_player.living_room")
    }
}
