import Foundation
import Testing
@testable import HA_Voice

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task {
            if let handler = Self.requestHandler {
                do {
                    let (response, data) = try await handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            } else {
                let response = HTTPURLResponse(url: request.url ?? URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime: Date
    private var _sleepDurations: [TimeInterval] = []
    nonisolated(unsafe) var onSleep: (@Sendable (TimeInterval) async throws -> Void)?

    init(start: Date = Date(timeIntervalSince1970: 10_000)) {
        self._currentTime = start
    }

    var currentTime: Date {
        lock.withLock { _currentTime }
    }

    var sleepDurations: [TimeInterval] {
        lock.withLock { _sleepDurations }
    }

    func now() -> Date {
        lock.withLock { _currentTime }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            _currentTime = _currentTime.addingTimeInterval(seconds)
        }
    }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock {
            _sleepDurations.append(seconds)
            _currentTime = _currentTime.addingTimeInterval(seconds)
        }
        if let onSleep {
            try await onSleep(seconds)
        }
        await Task.yield()
    }
}

private struct TimeoutError: Error {}

@MainActor
private func waitUntil(timeout: TimeInterval = 2.0, condition: @MainActor () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > timeout {
            throw TimeoutError()
        }
        await Task.yield()
    }
}

@Suite(.serialized)
@MainActor
struct SessionLifecycleTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen",
        state: "idle"
    )

    private func makeAppState(clock: TestClock) -> AppState {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = HomeAssistantClient(urlSession: URLSession(configuration: config))
        let defaults = UserDefaults(suiteName: "SessionLifecycleTests-\(UUID().uuidString)")!

        let state = AppState(
            client: client,
            keychain: KeychainTokenStore(),
            defaults: defaults,
            now: { clock.now() },
            sleep: { seconds in try await clock.sleep(seconds: seconds) }
        )
        state.serverProfile = ServerProfile(serverURL: "http://homeassistant.local:8123", displayName: "Home Assistant", lastConnectionStatus: .connected)
        state.token = "test-token"
        state.mediaPlayers = [kitchen]
        state.selectedTargetID = kitchen.entityID
        return state
    }

    // MARK: - Bug 1: Countdown Timing

    @Test func countdownDivisibleIntervalScheduleAndFinalMessageTiming() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        // 10 minutes total, 5 minutes interval -> divisible
        appState.startCountdown(
            totalDuration: 10 * 60,
            interval: 5 * 60,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes until it's time to go.",
            finalMessage: "It's time to go."
        )

        try await waitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        #expect(clock.sleepDurations == [300, 300])
        #expect(appState.messages.count == 3)

        // First interval send at t=0
        #expect(appState.messages[0].detail == "10 min remaining")
        #expect(appState.messages[0].text == "You have 10 minutes until it's time to go.")

        // Second interval send at t=300
        #expect(appState.messages[1].detail == "5 min remaining")
        #expect(appState.messages[1].text == "You have 5 minutes until it's time to go.")

        // Final send at exactly totalDuration (t=600)
        #expect(appState.messages[2].detail == "Final")
        #expect(appState.messages[2].text == "It's time to go.")
        #expect(appState.countdownSessions.first?.remaining == 0)
    }

    @Test func countdownNonDivisibleIntervalScheduleAndFinalMessageTiming() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        // 10 minutes total, 4 minutes interval -> non-divisible
        appState.startCountdown(
            totalDuration: 10 * 60,
            interval: 4 * 60,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes until it's time to go.",
            finalMessage: "It's time to go."
        )

        try await waitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        // Sleep durations should be min(interval, remaining): 240, 240, then min(240, 120) = 120
        #expect(clock.sleepDurations == [240, 240, 120])
        #expect(clock.sleepDurations.reduce(0, +) == 600)
        #expect(appState.messages.count == 4)

        #expect(appState.messages[0].detail == "10 min remaining")
        #expect(appState.messages[1].detail == "6 min remaining")
        #expect(appState.messages[2].detail == "2 min remaining")
        #expect(appState.messages[3].detail == "Final")
        #expect(appState.messages[3].text == "It's time to go.")
        #expect(appState.countdownSessions.first?.remaining == 0)
    }

    // MARK: - Bug 3: Cancellation Status

    @Test func cancellationMidSendRecordsCancelledStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Hello",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await waitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    @Test func stoppingRepeatMidSendMarksMessageCancelled() async throws {
        MockURLProtocol.requestHandler = { _ in
            try await Task.sleep(for: .milliseconds(500))
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Hello",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await waitUntil {
            appState.messages.first?.status == .sending
        }

        let session = try #require(appState.repeatSessions.first)
        appState.stopRepeat(session)

        try await waitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    @Test func stoppingCountdownMidSendMarksMessageCancelled() async throws {
        MockURLProtocol.requestHandler = { _ in
            try await Task.sleep(for: .milliseconds(500))
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        appState.startCountdown(
            totalDuration: 600,
            interval: 300,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes.",
            finalMessage: "Done."
        )

        try await waitUntil {
            appState.messages.first?.status == .sending
        }

        let session = try #require(appState.countdownSessions.first)
        appState.stopCountdown(session)

        try await waitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    // MARK: - Bug 4: Repeat Message Detail Computed Per Send

    @Test func repeatMessageDetailComputedPerSend() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Dinner is ready",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await waitUntil {
            appState.repeatSessions.first?.status == .completed
        }

        #expect(appState.messages.count == 3)
        #expect(appState.messages.map(\.detail) == ["Repeating 1/3", "Repeating 2/3", "Repeating 3/3"])
        #expect(appState.repeatSessions.first?.status == .completed)
    }

    @Test func repeatByDurationCompletionRules() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        // 60 seconds duration, 25 seconds interval
        appState.startRepeat(
            message: "Testing duration",
            target: kitchen,
            voice: .defaultPreset,
            interval: 25,
            limit: .duration(60)
        )

        try await waitUntil {
            appState.repeatSessions.first?.status == .completed
        }

        // Sends at t=0, t=25, t=50. At t=75 (or next check), elapsed >= 60, completes.
        #expect(appState.messages.count == 3)
        #expect(appState.messages.allSatisfy { $0.detail == "Repeating for 1 min" })
        #expect(appState.repeatSessions.first?.status == .completed)
    }

    // MARK: - Bug 2: Background Expiry, Paused Lifecycle, Resume, and Stop

    @Test func backgroundExpiryPausesSessionsAndCancelsTasks() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        var pausedDuringSleep = false
        clock.onSleep = { _ in
            if !pausedDuringSleep {
                pausedDuringSleep = true
                Task { @MainActor in
                    appState.handleBackgroundExpiration()
                }
            }
        }

        appState.startCountdown(
            totalDuration: 600,
            interval: 300,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes.",
            finalMessage: "Done."
        )

        try await waitUntil {
            pausedDuringSleep && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let session = try #require(appState.countdownSessions.first)
        #expect(session.status == .pausedBySystem)
        #expect(appState.activeCountdownSessions.contains { $0.id == session.id })
        #expect(appState.hasActiveSessions)
        #expect(appState.backgroundWarning != nil)

        // Clear sleep handler and advance clock — no further sends should occur because task was cancelled
        clock.onSleep = nil
        let messageCountBefore = appState.messages.count
        clock.advance(by: 400)
        await Task.yield()

        #expect(appState.messages.count == messageCountBefore)
    }

    @Test func resumeCountdownBeforeDeadlineContinuesFromRealElapsedTime() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        var didPause = false
        clock.onSleep = { _ in
            if !didPause {
                didPause = true
                Task { @MainActor in
                    appState.handleBackgroundExpiration()
                }
            }
        }

        appState.startCountdown(
            totalDuration: 600,
            interval: 300,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes.",
            finalMessage: "Done."
        )

        try await waitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil

        // Advance by 120s (total elapsed: 300 + 120 = 420s -> remaining = 180s = 3 minutes)
        clock.advance(by: 120)

        appState.resumeCountdown(pausedSession)

        try await waitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        // Resumed interval message at t=420 (3 min remaining), followed by final message at t=600
        #expect(appState.messages.contains { $0.detail == "3 min remaining" })
        let finalMsg = try #require(appState.messages.last)
        #expect(finalMsg.detail == "Final")
        #expect(finalMsg.text == "Done.")
        #expect(appState.countdownSessions.first?.remaining == 0)
    }

    @Test func resumeCountdownAfterDeadlineSendsOnlyFinalMessage() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        var didPause = false
        clock.onSleep = { _ in
            if !didPause {
                didPause = true
                Task { @MainActor in
                    appState.handleBackgroundExpiration()
                }
            }
        }

        appState.startCountdown(
            totalDuration: 600,
            interval: 300,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes.",
            finalMessage: "Done."
        )

        try await waitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil

        // Advance past deadline (e.g. 500s elapsed since sleep at t=300 -> total 800s > 600s)
        clock.advance(by: 500)
        let messagesBeforeResume = appState.messages.count

        appState.resumeCountdown(pausedSession)

        try await waitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        // Exactly one new message should have been sent: the final message!
        #expect(appState.messages.count == messagesBeforeResume + 1)
        let lastMessage = try #require(appState.messages.last)
        #expect(lastMessage.detail == "Final")
        #expect(lastMessage.text == "Done.")
        #expect(appState.countdownSessions.first?.remaining == 0)
    }

    @Test func stopPausedSessionRemovesItFromActiveSessions() async throws {
        MockURLProtocol.requestHandler = nil
        let clock = TestClock()
        let appState = makeAppState(clock: clock)

        var didPause = false
        clock.onSleep = { _ in
            if !didPause {
                didPause = true
                Task { @MainActor in
                    appState.handleBackgroundExpiration()
                }
            }
        }

        appState.startRepeat(
            message: "Check oven",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(5)
        )

        try await waitUntil {
            didPause && appState.repeatSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.repeatSessions.first)
        #expect(appState.activeRepeatSessions.count == 1)

        appState.stopRepeat(pausedSession)
        #expect(appState.activeRepeatSessions.isEmpty)
        #expect(appState.repeatSessions.isEmpty)
    }
}
