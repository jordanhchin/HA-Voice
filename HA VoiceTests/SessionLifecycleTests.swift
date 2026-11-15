import Foundation
import Testing
@testable import HA_Voice

final class SessionMockURLProtocol: URLProtocol, @unchecked Sendable {
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

final class SessionTestClock: @unchecked Sendable {
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

private struct SessionTimeoutError: Error {}

@MainActor
private func sessionWaitUntil(timeout: TimeInterval = 2.0, condition: @MainActor () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > timeout {
            throw SessionTimeoutError()
        }
        await Task.yield()
    }
}

private final class SessionAtomicBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestCount: Int = 0
    private var _isUnblocked = false

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    func incrementRequestCount() -> Int {
        lock.withLock {
            _requestCount += 1
            return _requestCount
        }
    }

    func unblock() {
        lock.withLock { _isUnblocked = true }
    }

    var canProceed: Bool {
        lock.withLock { _isUnblocked }
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

    private func makeAppState(clock: SessionTestClock) -> AppState {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionMockURLProtocol.self]
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
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
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
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
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
        SessionMockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Hello",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await sessionWaitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    @Test func stoppingRepeatMidSendMarksMessageCancelled() async throws {
        SessionMockURLProtocol.requestHandler = { _ in
            try await Task.sleep(for: .milliseconds(500))
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Hello",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await sessionWaitUntil {
            appState.messages.first?.status == .sending
        }

        let session = try #require(appState.repeatSessions.first)
        appState.stopRepeat(session)

        try await sessionWaitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    @Test func stoppingCountdownMidSendMarksMessageCancelled() async throws {
        SessionMockURLProtocol.requestHandler = { _ in
            try await Task.sleep(for: .milliseconds(500))
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startCountdown(
            totalDuration: 600,
            interval: 300,
            target: kitchen,
            voice: .defaultPreset,
            template: "You have {minutes} minutes.",
            finalMessage: "Done."
        )

        try await sessionWaitUntil {
            appState.messages.first?.status == .sending
        }

        let session = try #require(appState.countdownSessions.first)
        appState.stopCountdown(session)

        try await sessionWaitUntil {
            !appState.messages.isEmpty && appState.messages.first?.status != .sending
        }

        let message = try #require(appState.messages.first)
        #expect(message.status == .cancelled)
        #expect(message.errorMessage == nil)
    }

    // MARK: - Bug 4: Repeat Message Detail Computed Per Send

    @Test func repeatMessageDetailComputedPerSend() async throws {
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Dinner is ready",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await sessionWaitUntil {
            appState.repeatSessions.first?.status == .completed
        }

        #expect(appState.messages.count == 3)
        #expect(appState.messages.map(\.detail) == ["Repeating 1/3", "Repeating 2/3", "Repeating 3/3"])
        #expect(appState.repeatSessions.first?.status == .completed)
    }

    @Test func repeatByDurationCompletionRules() async throws {
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        // 60 seconds duration, 25 seconds interval
        appState.startRepeat(
            message: "Testing duration",
            target: kitchen,
            voice: .defaultPreset,
            interval: 25,
            limit: .duration(60)
        )

        try await sessionWaitUntil {
            appState.repeatSessions.first?.status == .completed
        }

        // Sends at t=0, t=25, t=50. At t=75 (or next check), elapsed >= 60, completes.
        #expect(appState.messages.count == 3)
        #expect(appState.messages.allSatisfy { $0.detail == "Repeating for 1 min" })
        #expect(appState.repeatSessions.first?.status == .completed)
    }

    // MARK: - Bug 2: Background Expiry, Paused Lifecycle, Resume, and Stop

    @Test func backgroundExpiryPausesSessionsAndCancelsTasks() async throws {
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
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
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil

        // Advance by 120s (total elapsed: 300 + 120 = 420s -> remaining = 180s = 3 minutes)
        clock.advance(by: 120)

        appState.resumeCountdown(pausedSession)

        try await sessionWaitUntil {
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
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil

        // Paused at t=300 (deadline is t=600).
        // Advance past deadline (400s -> total 700s, 100s past deadline <= 300s cutoff)
        clock.advance(by: 400)
        let messagesBeforeResume = appState.messages.count

        appState.resumeCountdown(pausedSession)

        try await sessionWaitUntil {
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
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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

        try await sessionWaitUntil {
            didPause && appState.repeatSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.repeatSessions.first)
        #expect(appState.activeRepeatSessions.count == 1)

        appState.stopRepeat(pausedSession)
        #expect(appState.activeRepeatSessions.isEmpty)
        #expect(appState.repeatSessions.isEmpty)
    }

    // MARK: - Round 2 Integration Review Tests

    @Test func stoppingOneRepeatSessionLeavesConcurrentRepeatSessionIntact() async throws {
        let barrier = SessionAtomicBarrier()
        SessionMockURLProtocol.requestHandler = { _ in
            _ = barrier.incrementRequestCount()
            while !barrier.canProceed {
                try await Task.sleep(for: .milliseconds(20))
            }
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Session Alpha",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )
        appState.startRepeat(
            message: "Session Beta",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(3)
        )

        try await sessionWaitUntil {
            barrier.requestCount >= 2
        }

        let alphaSession = try #require(appState.repeatSessions.first(where: { $0.message == "Session Alpha" }))
        let betaSession = try #require(appState.repeatSessions.first(where: { $0.message == "Session Beta" }))

        // Stop Alpha session while both are in-flight
        appState.stopRepeat(alphaSession)

        // Alpha message should be cancelled immediately
        let alphaMessage = try #require(appState.messages.first(where: { $0.text == "Session Alpha" }))
        #expect(alphaMessage.status == .cancelled)
        #expect(!appState.repeatSessions.contains { $0.id == alphaSession.id })

        // Beta message should still be sending and Beta session still running
        let betaMessageBefore = try #require(appState.messages.first(where: { $0.text == "Session Beta" }))
        #expect(betaMessageBefore.status == .sending)
        #expect(appState.repeatSessions.contains { $0.id == betaSession.id })

        // Now allow network completion
        barrier.unblock()

        try await sessionWaitUntil {
            appState.messages.first(where: { $0.text == "Session Beta" })?.status == .sent
        }

        let betaMessageAfter = try #require(appState.messages.first(where: { $0.text == "Session Beta" }))
        #expect(betaMessageAfter.status == .sent)
        #expect(appState.repeatSessions.contains { $0.id == betaSession.id })

        // Clean up Beta session
        if let currentBeta = appState.repeatSessions.first(where: { $0.id == betaSession.id }) {
            appState.stopRepeat(currentBeta)
        }
    }

    @Test func cancelledFinalRepeatSendLeavesSessionPausedAndResumable() async throws {
        let barrier = SessionAtomicBarrier()
        SessionMockURLProtocol.requestHandler = { _ in
            let count = barrier.incrementRequestCount()
            if count == 2 {
                while !barrier.canProceed {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        appState.startRepeat(
            message: "Oven check",
            target: kitchen,
            voice: .defaultPreset,
            interval: 10,
            limit: .count(2)
        )

        // Wait until final send attempt (request #2) is in flight
        try await sessionWaitUntil {
            barrier.requestCount >= 2
        }

        // Simulate background expiration while final send is in flight
        appState.handleBackgroundExpiration()

        let pausedSession = try #require(appState.repeatSessions.first)
        #expect(pausedSession.status == .pausedBySystem)
        // sentCount should NOT have been incremented for the failed/cancelled final send
        #expect(pausedSession.sentCount == 1)

        // Wait until cancellation finishes unwinding
        try await sessionWaitUntil {
            appState.messages.last?.status == .cancelled
        }
        let cancelledMsg = try #require(appState.messages.last)
        #expect(cancelledMsg.status == .cancelled)

        // Allow network handler to proceed and unblock any waiting tasks
        barrier.unblock()
        SessionMockURLProtocol.requestHandler = nil

        // Resuming the repeat session should deliver the remaining 2nd message and complete
        appState.resumeRepeat(pausedSession)

        try await sessionWaitUntil {
            appState.repeatSessions.first?.status == .completed
        }

        let completedSession = try #require(appState.repeatSessions.first)
        #expect(completedSession.status == .completed)
        #expect(completedSession.sentCount == 2)
        let lastMsg = try #require(appState.messages.last)
        #expect(lastMsg.status == .sent)
        #expect(lastMsg.detail == "Repeating 2/2")
    }

    @Test func cancelledFinalCountdownSendLeavesSessionPausedAndResumable() async throws {
        let barrier = SessionAtomicBarrier()
        SessionMockURLProtocol.requestHandler = { _ in
            let count = barrier.incrementRequestCount()
            if count == 2 {
                while !barrier.canProceed {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
        let appState = makeAppState(clock: clock)

        // 20s total, 20s interval -> 1 interval send at t=0, then final send at t=20
        appState.startCountdown(
            totalDuration: 20,
            interval: 20,
            target: kitchen,
            voice: .defaultPreset,
            template: "{minutes} min left",
            finalMessage: "Final Countdown Over"
        )

        // Wait until final message send (request #2) is in flight
        try await sessionWaitUntil {
            barrier.requestCount >= 2
        }

        // Simulate background expiration while final message is in flight
        appState.handleBackgroundExpiration()

        let pausedSession = try #require(appState.countdownSessions.first)
        #expect(pausedSession.status == .pausedBySystem)

        // Unblock network handler
        barrier.unblock()
        SessionMockURLProtocol.requestHandler = nil

        // Resuming countdown should successfully deliver final message and complete
        appState.resumeCountdown(pausedSession)

        try await sessionWaitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        let completedSession = try #require(appState.countdownSessions.first)
        #expect(completedSession.status == .completed)
        #expect(completedSession.remaining == 0)
        let lastMsg = try #require(appState.messages.last)
        #expect(lastMsg.status == .sent)
        #expect(lastMsg.detail == "Final")
        #expect(lastMsg.text == "Final Countdown Over")
    }

    @Test func countdownDriftCompensationUnderSendLatency() async throws {
        let clock = SessionTestClock()
        // Simulate 5 seconds latency on every TTS send
        SessionMockURLProtocol.requestHandler = { _ in
            clock.advance(by: 5)
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let appState = makeAppState(clock: clock)

        // 60 seconds total, 20 seconds interval
        // Sends at t=0, t=20, t=40, and final at t=60.
        // Each send advances clock by 5s.
        // With drift compensation, sleep durations should be:
        // after t=0 (returns at t=5): next target t=20 -> sleeps 15s
        // after t=20 (returns at t=25): next target t=40 -> sleeps 15s
        // after t=40 (returns at t=45): next target t=60 -> sleeps 15s
        // at t=60: final send occurs, completing the session.
        appState.startCountdown(
            totalDuration: 60,
            interval: 20,
            target: kitchen,
            voice: .defaultPreset,
            template: "{minutes} min left",
            finalMessage: "Time is up!"
        )

        try await sessionWaitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        #expect(clock.sleepDurations == [15, 15, 15])
        #expect(appState.messages.count == 4)
        #expect(appState.messages.map(\.detail) == ["1 min remaining", "1 min remaining", "1 min remaining", "Final"])
    }

    @Test func resumeCountdownAtDeadlinePlusFourMinutesAnnouncesFinalMessage() async throws {
        SessionMockURLProtocol.requestHandler = nil
        let clock = SessionTestClock()
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
            template: "{minutes} min remaining",
            finalMessage: "Time to leave!"
        )

        try await sessionWaitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil

        // Paused at t=300 (deadline is t=600).
        // Advance by 300s + 240s (4 minutes past deadline = 540s total advance)
        clock.advance(by: 540)

        let messageCountBefore = appState.messages.count
        appState.resumeCountdown(pausedSession)

        try await sessionWaitUntil {
            appState.countdownSessions.first?.status == .completed
        }

        // Final message announced because overdue (4 min) <= 5 min staleness cutoff
        #expect(appState.messages.count == messageCountBefore + 1)
        let lastMessage = try #require(appState.messages.last)
        #expect(lastMessage.detail == "Final")
        #expect(lastMessage.text == "Time to leave!")
        #expect(lastMessage.status == .sent)
        #expect(appState.countdownSessions.first?.remaining == 0)
    }

    @Test func resumeCountdownAtDeadlinePlusSixMinutesExpiresWithoutAnnouncement() async throws {
        var networkRequestMade = false
        SessionMockURLProtocol.requestHandler = { _ in
            networkRequestMade = true
            return (HTTPURLResponse(url: URL(string: "http://homeassistant.local:8123")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = SessionTestClock()
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
            template: "{minutes} min remaining",
            finalMessage: "Time to leave!"
        )

        try await sessionWaitUntil {
            didPause && appState.countdownSessions.first?.status == .pausedBySystem
        }

        let pausedSession = try #require(appState.countdownSessions.first)
        clock.onSleep = nil
        networkRequestMade = false

        // Paused at t=300 (deadline is t=600).
        // Advance by 300s + 360s (6 minutes past deadline = 660s total advance)
        clock.advance(by: 660)

        appState.resumeCountdown(pausedSession)

        try await sessionWaitUntil {
            appState.countdownSessions.first?.status == .expired
        }

        // No network request made because overdue (6 min) > 5 min staleness cutoff
        #expect(!networkRequestMade)

        let session = try #require(appState.countdownSessions.first)
        #expect(session.status == .expired)
        #expect(session.remaining == 0)

        // History record logged with .cancelled and "Expired – not announced"
        let lastMessage = try #require(appState.messages.last)
        #expect(lastMessage.status == .cancelled)
        #expect(lastMessage.kind == .countdown)
        #expect(lastMessage.detail == "Expired – not announced")
        #expect(lastMessage.text == "Time to leave!")
    }
}
