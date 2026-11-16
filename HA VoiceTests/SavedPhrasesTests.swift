import Foundation
import Testing
@testable import HA_Voice

final class PhraseMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func setHandler(forToken token: String, handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.withLock {
            handlers["Bearer \(token)"] = handler
        }
    }

    static func removeHandler(forToken token: String) {
        lock.withLock {
            handlers.removeValue(forKey: "Bearer \(token)")
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let handler = Self.lock.withLock { Self.handlers[auth] }

        guard let handler else {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://homeassistant.local:8123")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class PhraseTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime: Date

    init(start: Date = Date(timeIntervalSince1970: 10_000)) {
        self._currentTime = start
    }

    func now() -> Date {
        lock.withLock { _currentTime }
    }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock {
            _currentTime = _currentTime.addingTimeInterval(seconds)
        }
        await Task.yield()
    }
}

private struct PhraseTimeoutError: Error {}

@MainActor
private func phraseWaitUntil(timeout: TimeInterval = 2.0, condition: @MainActor () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > timeout {
            throw PhraseTimeoutError()
        }
        await Task.yield()
    }
}

@MainActor
struct ComposerDraftTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen",
        state: "idle"
    )

    private func makeAppState(clock: PhraseTestClock = PhraseTestClock(), token: String = "phrase-draft-token-\(UUID().uuidString)") -> (AppState, String) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhraseMockURLProtocol.self]
        let client = HomeAssistantClient(urlSession: URLSession(configuration: config))
        let defaults = UserDefaults(suiteName: "ComposerDraftTests-\(UUID().uuidString)")!

        let state = AppState(
            client: client,
            keychain: KeychainTokenStore(),
            defaults: defaults,
            now: { clock.now() },
            sleep: { seconds in try await clock.sleep(seconds: seconds) }
        )
        state.serverProfile = ServerProfile(serverURL: "http://homeassistant.local:8123", displayName: "Home Assistant", lastConnectionStatus: .connected)
        state.token = token
        state.mediaPlayers = [kitchen]
        state.selectedTargetIDs = [kitchen.entityID]
        return (state, token)
    }

    @Test func defaultsMatchPreviousComposerDefaults() {
        let draft = ComposerDraft()

        #expect(draft.message == "")
        #expect(draft.mode == .once)
        #expect(draft.repeatCount == 3)
        #expect(draft.repeatDurationMinutes == 5)
        #expect(draft.repeatIntervalSeconds == 60)
        #expect(draft.countdownMinutes == 10)
        #expect(draft.countdownIntervalMinutes == 1)
        #expect(draft.countdownTemplate == "You have {minutes} minutes until it's time to go.")
        #expect(draft.finalMessage == "It's time to go.")
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        let original = ComposerDraft(
            message: "Dinner is ready",
            mode: .countdown,
            repeatCount: 5,
            repeatDurationMinutes: 12,
            repeatIntervalSeconds: 45,
            countdownMinutes: 15,
            countdownIntervalMinutes: 3,
            countdownTemplate: "{minutes} mins left",
            finalMessage: "Come downstairs"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ComposerDraft.self, from: data)

        #expect(decoded == original)
    }

    @Test func sendComposerMessageOnceAndOnceAs() async throws {
        let (state, token) = makeAppState()
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        state.senderName = "Jordan"
        state.sendComposerMessage(ComposerDraft(message: "Hello house", mode: .once))

        try await phraseWaitUntil { state.messages.count == 1 && state.messages[0].status == .sent }
        #expect(state.messages[0].text == "Hello house")
        #expect(state.messages[0].kind == .single)
        #expect(state.messages[0].detail == nil)

        state.sendComposerMessage(ComposerDraft(message: "Time for lunch", mode: .onceAs))

        try await phraseWaitUntil { state.messages.count == 2 && state.messages[1].status == .sent }
        #expect(state.messages[1].text == "Jordan says: Time for lunch")
        #expect(state.messages[1].kind == .singleAs)
        #expect(state.messages[1].detail == "Jordan says")
    }

    @Test func sendComposerMessageRepeatCountUsesDraftSettings() async throws {
        let clock = PhraseTestClock()
        let (state, token) = makeAppState(clock: clock)
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let draft = ComposerDraft(
            message: "Bus arrives soon",
            mode: .repeatCount,
            repeatCount: 2,
            repeatIntervalSeconds: 30
        )
        state.sendComposerMessage(draft)

        try await phraseWaitUntil { state.repeatSessions.first?.status == .completed }

        let session = try #require(state.repeatSessions.first)
        #expect(session.message == "Bus arrives soon")
        #expect(session.interval == 30)
        #expect(session.limit == .count(2))
        #expect(session.sentCount == 2)
    }

    @Test func sendComposerMessageCountdownUsesDraftSettings() async throws {
        let clock = PhraseTestClock()
        let (state, token) = makeAppState(clock: clock)
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let draft = ComposerDraft(
            mode: .countdown,
            countdownMinutes: 2,
            countdownIntervalMinutes: 2,
            countdownTemplate: "{minutes} remaining",
            finalMessage: "Time's up"
        )
        state.sendComposerMessage(draft)

        try await phraseWaitUntil { state.countdownSessions.first?.status == .completed }

        let session = try #require(state.countdownSessions.first)
        #expect(session.totalDuration == 120)
        #expect(session.interval == 120)
        #expect(session.template == "{minutes} remaining")
        #expect(session.finalMessage == "Time's up")
        #expect(state.messages.map(\.text) == ["2 remaining", "Time's up"])
    }
}

@MainActor
struct SavedPhraseTests {
    private let kitchen = MediaPlayerTarget(entityID: "media_player.kitchen", friendlyName: "Kitchen", state: "idle")
    private let office = MediaPlayerTarget(entityID: "media_player.office", friendlyName: "Office", state: "idle")
    private let bedroom = MediaPlayerTarget(entityID: "media_player.bedroom", friendlyName: "Bedroom", state: "idle")
    private let cloudEngine = TTSEngine(entityID: VoicePreset.cloudEngineID, name: "Home Assistant Cloud")
    private let piperEngine = TTSEngine(entityID: "tts.piper", name: "Piper")

    private func makeAppState(
        suiteName: String = "SavedPhraseTests-\(UUID().uuidString)",
        token: String = "saved-phrase-token-\(UUID().uuidString)"
    ) -> (AppState, String, String) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhraseMockURLProtocol.self]
        let client = HomeAssistantClient(urlSession: URLSession(configuration: config))
        let defaults = UserDefaults(suiteName: suiteName)!

        let state = AppState(
            client: client,
            keychain: KeychainTokenStore(),
            defaults: defaults
        )
        state.serverProfile = ServerProfile(serverURL: "http://homeassistant.local:8123", displayName: "Home Assistant", lastConnectionStatus: .connected)
        state.token = token
        state.mediaPlayers = [kitchen, office, bedroom]
        state.ttsEngines = [cloudEngine, piperEngine]
        state.selectedTargetIDs = [kitchen.entityID]
        return (state, suiteName, token)
    }

    @Test func saveUpdateRenameMoveDeleteAndPersistAcrossReload() throws {
        let suiteName = "SavedPhrasePersist-\(UUID().uuidString)"
        let (state, _, token) = makeAppState(suiteName: suiteName)
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let jenny = try #require(VoicePreset.builtIns.first { $0.name == "Jenny" })
        let guy = try #require(VoicePreset.builtIns.first { $0.name == "Guy" })

        state.selectedTargetIDs = [office.entityID, kitchen.entityID]
        state.selectedVoiceID = jenny.id
        let first = state.savePhrase(
            name: "  Dinner  ",
            draft: ComposerDraft(message: "Dinner is ready", mode: .once)
        )
        #expect(first.name == "Dinner")
        #expect(first.targetIDs == [office.entityID, kitchen.entityID])
        #expect(first.voicePresetID == jenny.id)

        state.selectedTargetIDs = [bedroom.entityID]
        state.selectedVoiceID = guy.id
        let second = state.savePhrase(
            name: "Bedtime",
            draft: ComposerDraft(mode: .countdown, countdownMinutes: 15, finalMessage: "Lights out")
        )
        #expect(state.savedPhrases.map(\.id) == [first.id, second.id])

        // Update first phrase with current composer + speaker/voice selection
        let updatedDraft = ComposerDraft(message: "Supper time", mode: .repeatCount, repeatCount: 2, repeatIntervalSeconds: 20)
        state.updatePhrase(first, with: updatedDraft)
        #expect(state.savedPhrases[0].draft == updatedDraft)
        #expect(state.savedPhrases[0].targetIDs == [bedroom.entityID])
        #expect(state.savedPhrases[0].voicePresetID == guy.id)
        #expect(state.savedPhrases[0].name == "Dinner")

        // Rename and ignore blank rename
        state.renamePhrase(first, to: "  Supper  ")
        #expect(state.savedPhrases[0].name == "Supper")
        state.renamePhrase(first, to: "   ")
        #expect(state.savedPhrases[0].name == "Supper")

        // Reorder
        state.movePhrases(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(state.savedPhrases.map(\.id) == [second.id, first.id])

        // Reload from UserDefaults and confirm persisted order & edits
        let reloaded = AppState(
            client: HomeAssistantClient(),
            keychain: KeychainTokenStore(),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        #expect(reloaded.savedPhrases.count == 2)
        #expect(reloaded.savedPhrases[0] == state.savedPhrases[0])
        #expect(reloaded.savedPhrases[1] == state.savedPhrases[1])

        // Delete
        reloaded.deletePhrase(second)
        #expect(reloaded.savedPhrases.map(\.id) == [first.id])

        let reloadedAfterDelete = AppState(
            client: HomeAssistantClient(),
            keychain: KeychainTokenStore(),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        #expect(reloadedAfterDelete.savedPhrases.map(\.id) == [first.id])
    }

    @Test func applyPhraseRestoresSpeakersInOrderAndVoiceWithoutSending() async throws {
        let (state, _, token) = makeAppState()
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        var requestCount = 0
        PhraseMockURLProtocol.setHandler(forToken: token) { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let jenny = try #require(VoicePreset.builtIns.first { $0.name == "Jenny" })
        state.selectedTargetIDs = [kitchen.entityID]
        state.selectedVoiceID = VoicePreset.defaultPreset.id

        let phrase = SavedPhrase(
            name: "Office & Bedroom",
            draft: ComposerDraft(message: "Hello", mode: .once),
            targetIDs: [bedroom.entityID, office.entityID],
            voicePresetID: jenny.id
        )

        let result = state.apply(phrase)

        #expect(result == PhraseApplyResult(missingSpeakerCount: 0, allSpeakersMissing: false, voiceUnavailable: false))
        #expect(result.noticeMessage == nil)
        #expect(state.selectedTargetIDs == [bedroom.entityID, office.entityID])
        #expect(state.selectedTargets == [bedroom, office])
        #expect(state.selectedVoiceID == jenny.id)
        #expect(state.messages.isEmpty)
        #expect(state.repeatSessions.isEmpty)
        #expect(state.countdownSessions.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(requestCount == 0)
    }

    @Test func applyPhraseHandlesPartialMissingSpeakers() throws {
        let (state, _, token) = makeAppState()
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let guy = try #require(VoicePreset.builtIns.first { $0.name == "Guy" })
        let phrase = SavedPhrase(
            name: "Mixed Speakers",
            draft: ComposerDraft(message: "Notice", mode: .once),
            targetIDs: [office.entityID, "media_player.removed", kitchen.entityID],
            voicePresetID: guy.id
        )

        let result = state.apply(phrase)

        #expect(result.missingSpeakerCount == 1)
        #expect(!result.allSpeakersMissing)
        #expect(!result.voiceUnavailable)
        #expect(result.noticeMessage != nil)
        #expect(state.selectedTargetIDs == [office.entityID, kitchen.entityID])
        #expect(state.selectedVoiceID == guy.id)
    }

    @Test func applyPhraseKeepsCurrentSpeakersWhenAllPhraseSpeakersMissing() throws {
        let (state, _, token) = makeAppState()
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let guy = try #require(VoicePreset.builtIns.first { $0.name == "Guy" })
        state.selectedTargetIDs = [kitchen.entityID, office.entityID]

        let phrase = SavedPhrase(
            name: "Gone Speakers",
            draft: ComposerDraft(message: "Hello", mode: .once),
            targetIDs: ["media_player.gone1", "media_player.gone2"],
            voicePresetID: guy.id
        )

        let result = state.apply(phrase)

        #expect(result.missingSpeakerCount == 2)
        #expect(result.allSpeakersMissing)
        #expect(!result.voiceUnavailable)
        #expect(result.noticeMessage != nil)
        #expect(state.selectedTargetIDs == [kitchen.entityID, office.entityID])
        #expect(state.selectedVoiceID == guy.id)
    }

    @Test func applyPhraseKeepsCurrentVoiceWhenPresetDeletedOrEngineUnavailable() {
        let (state, _, token) = makeAppState()
        defer { PhraseMockURLProtocol.removeHandler(forToken: token) }

        let customPreset = VoicePreset(
            id: UUID(),
            name: "Piper Voice",
            language: "en-US",
            voice: "lessac",
            isCustom: true,
            engineID: "tts.piper"
        )
        state.addOrUpdateVoice(customPreset)

        let defaultID = VoicePreset.defaultPreset.id
        state.selectedVoiceID = defaultID

        // 1. Deleted preset ID
        let deletedVoicePhrase = SavedPhrase(
            name: "Deleted Voice",
            draft: ComposerDraft(message: "Hi", mode: .once),
            targetIDs: [office.entityID],
            voicePresetID: UUID()
        )
        let deletedResult = state.apply(deletedVoicePhrase)
        #expect(deletedResult.voiceUnavailable)
        #expect(deletedResult.missingSpeakerCount == 0)
        #expect(deletedResult.noticeMessage != nil)
        #expect(state.selectedVoiceID == defaultID)
        #expect(state.selectedTargetIDs == [office.entityID])

        // 2. Preset exists, but its engine (tts.piper) is no longer on the server
        state.ttsEngines = [cloudEngine]
        #expect(!state.isPresetAvailable(customPreset))

        let unavailableEnginePhrase = SavedPhrase(
            name: "Piper Phrase",
            draft: ComposerDraft(message: "Hi", mode: .once),
            targetIDs: [bedroom.entityID],
            voicePresetID: customPreset.id
        )
        let unavailableResult = state.apply(unavailableEnginePhrase)
        #expect(unavailableResult.voiceUnavailable)
        #expect(unavailableResult.noticeMessage != nil)
        #expect(state.selectedVoiceID == defaultID)
        #expect(state.selectedTargetIDs == [bedroom.entityID])
        #expect(state.hasUnavailableTargetOrVoice(for: unavailableEnginePhrase))
    }
}

