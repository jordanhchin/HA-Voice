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
