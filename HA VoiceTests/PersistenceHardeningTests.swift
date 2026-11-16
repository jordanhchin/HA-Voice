import Foundation
import Testing
@testable import HA_Voice

struct PersistenceHardeningTests {
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

    @Test func roundTripAppState() throws {
        let voice = VoicePreset(
            id: UUID(),
            name: "Custom Voice",
            language: "en-US",
            voice: "CustomNeural",
            isCustom: true,
            engineID: "tts.piper"
        )
        let engine = TTSEngine(entityID: "tts.piper", name: "Piper")
        let record = MessageRecord(
            id: UUID(),
            text: "Dinner is ready",
            targets: [kitchen, office],
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
            selectedTargetIDs: [kitchen.entityID, office.entityID],
            selectedVoiceID: voice.id,
            mediaPlayers: [kitchen, office],
            ttsEngines: [engine],
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
        #expect(decoded.selectedTargetIDs == [kitchen.entityID, office.entityID])
        #expect(decoded.selectedVoiceID == voice.id)
        #expect(decoded.mediaPlayers.count == 2)
        #expect(decoded.mediaPlayers.map(\.entityID) == [kitchen.entityID, office.entityID])
        #expect(decoded.ttsEngines == [engine])
        #expect(decoded.voicePresets.first?.engineID == "tts.piper")
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages.first?.text == "Dinner is ready")
        #expect(decoded.messages.first?.targets == [kitchen, office])
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
        #expect(decoded.selectedTargetIDs.isEmpty)
        #expect(decoded.selectedVoiceID == VoicePreset.defaultPreset.id)
        #expect(decoded.mediaPlayers.isEmpty)
        #expect(decoded.ttsEngines.isEmpty)
        #expect(decoded.voicePresets == VoicePreset.builtIns)
        #expect(decoded.messages.isEmpty)
    }

    @Test func migratesLegacySelectedTargetIDSingleTargetMessagesAndPresetsWithoutEngineID() throws {
        let legacyJSON = """
        {
            "serverProfile": {
                "serverURL": "https://ha.local:8123",
                "displayName": "Home Assistant",
                "lastConnectionStatus": "connected"
            },
            "senderName": "Jordan",
            "selectedTargetID": "media_player.kitchen",
            "selectedVoiceID": "44444444-4444-4444-4444-444444444444",
            "mediaPlayers": [
                {
                    "entityID": "media_player.kitchen",
                    "friendlyName": "Kitchen",
                    "state": "idle"
                }
            ],
            "voicePresets": [
                {
                    "id": "44444444-4444-4444-4444-444444444444",
                    "name": "Legacy Custom Preset",
                    "language": "en-US",
                    "voice": "LegacyVoice",
                    "isCustom": true
                }
            ],
            "messages": [
                {
                    "id": "55555555-5555-5555-5555-555555555555",
                    "text": "Migrated message",
                    "target": {
                        "entityID": "media_player.kitchen",
                        "friendlyName": "Kitchen",
                        "state": "idle"
                    },
                    "voicePreset": {
                        "id": "44444444-4444-4444-4444-444444444444",
                        "name": "Legacy Custom Preset",
                        "language": "en-US",
                        "voice": "LegacyVoice",
                        "isCustom": true
                    },
                    "sentAt": 1700000000,
                    "status": "sent",
                    "kind": "single"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let migrated = try decoder.decode(PersistedAppState.self, from: legacyJSON)

        #expect(migrated.selectedTargetIDs == ["media_player.kitchen"])
        #expect(migrated.voicePresets.count == 1)
        #expect(migrated.voicePresets[0].name == "Legacy Custom Preset")
        #expect(migrated.voicePresets[0].engineID == nil)
        #expect(migrated.messages.count == 1)
        #expect(migrated.messages[0].targets == [kitchen])
        #expect(migrated.messages[0].voicePreset.engineID == nil)

        // Verify re-encoding and decoding keeps the migrated fields
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let reencoded = try encoder.encode(migrated)
        let roundTripped = try decoder.decode(PersistedAppState.self, from: reencoded)

        #expect(roundTripped.selectedTargetIDs == ["media_player.kitchen"])
        #expect(roundTripped.messages.first?.targets == [kitchen])
        #expect(roundTripped.voicePresets.first?.name == "Legacy Custom Preset")
        #expect(roundTripped.voicePresets.first?.engineID == nil)
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
        #expect(decoded.messages[0].targets == [kitchen])
        #expect(decoded.messages[1].text == "Second valid message")
        #expect(decoded.messages[1].targets == [kitchen])
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
