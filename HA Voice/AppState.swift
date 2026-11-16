import Foundation
import Observation
import OSLog
import UIKit

@MainActor
@Observable
final class AppState {
    var serverProfile = ServerProfile()
    var senderName = ""
    var token = ""
    var mediaPlayers: [MediaPlayerTarget] = []
    var ttsEngines: [TTSEngine] = []
    var selectedTargetIDs: [String] = []
    var voicePresets: [VoicePreset] = VoicePreset.builtIns
    var selectedVoiceID: UUID = VoicePreset.defaultPreset.id
    var messages: [MessageRecord] = []
    var repeatSessions: [RepeatSession] = []
    var countdownSessions: [CountdownSession] = []
    var isRefreshingDevices = false
    var setupError: String?
    var deviceError: String?
    var backgroundWarning: String?

    static let countdownStalenessCutoff: TimeInterval = 5 * 60

    private let client: HomeAssistantClient
    private let keychain: KeychainTokenStore
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var repeatTasks: [UUID: Task<Void, Never>] = [:]
    private var countdownTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionInFlightMessageIDs: [UUID: UUID] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(
        client: HomeAssistantClient,
        keychain: KeychainTokenStore,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        load()
    }

    convenience init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.init(
            client: HomeAssistantClient(),
            keychain: KeychainTokenStore(),
            defaults: .standard,
            now: now,
            sleep: sleep
        )
    }

    var hasServerConfiguration: Bool {
        !serverProfile.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && HomeAssistantClient.isValidToken(token)
    }

    var selectedTargets: [MediaPlayerTarget] {
        get {
            let byID = Dictionary(uniqueKeysWithValues: mediaPlayers.map { ($0.entityID, $0) })
            return PersistedAppState.uniqueTargetIDs(selectedTargetIDs).compactMap { byID[$0] }
        }
        set {
            selectedTargetIDs = PersistedAppState.uniqueTargetIDs(newValue.map(\.entityID))
            persist()
        }
    }

    func isTargetSelected(_ target: MediaPlayerTarget) -> Bool {
        selectedTargetIDs.contains(target.entityID)
    }

    func toggleTargetSelection(_ target: MediaPlayerTarget) {
        let currentIDs = PersistedAppState.uniqueTargetIDs(selectedTargetIDs)
        if currentIDs.contains(target.entityID) {
            let validSelected = selectedTargets.map(\.entityID)
            guard validSelected.count > 1 else { return }
            selectedTargetIDs = currentIDs.filter { $0 != target.entityID }
        } else {
            selectedTargetIDs = PersistedAppState.uniqueTargetIDs(currentIDs + [target.entityID])
        }
        persist()
    }

    func selectAllTargets() {
        let currentIDs = PersistedAppState.uniqueTargetIDs(selectedTargetIDs)
        let allIDs = mediaPlayers.map(\.entityID)
        selectedTargetIDs = PersistedAppState.uniqueTargetIDs(currentIDs + allIDs)
        persist()
    }

    func clearTargetSelection() {
        if let firstSelected = selectedTargets.first {
            selectedTargetIDs = [firstSelected.entityID]
        } else if let firstPlayer = mediaPlayers.first {
            selectedTargetIDs = [firstPlayer.entityID]
        } else {
            selectedTargetIDs = []
        }
        persist()
    }

    var selectedVoice: VoicePreset {
        get {
            voicePresets.first { $0.id == selectedVoiceID } ?? VoicePreset.defaultPreset
        }
        set {
            selectedVoiceID = newValue.id
            persist()
        }
    }

    var activeRepeatSessions: [RepeatSession] {
        repeatSessions.filter { $0.status.isActive }
    }

    var activeCountdownSessions: [CountdownSession] {
        countdownSessions.filter { $0.status.isActive }
    }

    var hasActiveSessions: Bool {
        !activeRepeatSessions.isEmpty || !activeCountdownSessions.isEmpty
    }

    func saveServer(serverURL: String, token: String, progress: ((String) -> Void)? = nil) async -> Bool {
        let previousProfile = serverProfile
        let previousToken = self.token
        let hadExistingConfiguration = hasServerConfiguration
        var didSaveToken = false

        progress?("Saving access token")
        serverProfile.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try keychain.saveToken(self.token)
            didSaveToken = true
            progress?("Testing Home Assistant connection")
            try await client.testConnection(serverURL: serverProfile.serverURL, token: self.token)
            serverProfile.lastConnectionStatus = .connected
            setupError = nil
            persist()
            progress?("Loading media players")
            await refreshMediaPlayers()
            progress?("Connected")
            return true
        } catch {
            if hadExistingConfiguration {
                serverProfile = previousProfile
                self.token = previousToken
                serverProfile.lastConnectionStatus = .failed
            } else {
                serverProfile = ServerProfile(lastConnectionStatus: .failed)
                self.token = ""
            }
            let restoreError = restoreTokenAfterFailedSave(
                didSaveToken: didSaveToken,
                hadExistingConfiguration: hadExistingConfiguration,
                previousToken: previousToken
            )
            setupError = restoreError ?? error.localizedDescription
            persist()
            progress?("Connection failed")
            return false
        }
    }

    private func restoreTokenAfterFailedSave(didSaveToken: Bool, hadExistingConfiguration: Bool, previousToken: String) -> String? {
        guard didSaveToken else { return nil }

        do {
            if hadExistingConfiguration {
                try keychain.saveToken(previousToken)
            } else {
                try keychain.deleteToken()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testConnection() async {
        do {
            try await client.testConnection(serverURL: serverProfile.serverURL, token: token)
            serverProfile.lastConnectionStatus = .connected
            setupError = nil
        } catch {
            serverProfile.lastConnectionStatus = .failed
            setupError = error.localizedDescription
        }
        persist()
    }

    func refreshMediaPlayers() async {
        guard hasServerConfiguration else { return }
        isRefreshingDevices = true
        deviceError = nil
        defer { isRefreshingDevices = false }

        do {
            let discovered = try await client.fetchMediaPlayersAndEngines(
                serverURL: serverProfile.serverURL,
                token: token
            )
            mediaPlayers = discovered.mediaPlayers
            ttsEngines = discovered.ttsEngines

            let validIDs = Set(mediaPlayers.map(\.entityID))
            let surviving = PersistedAppState.uniqueTargetIDs(selectedTargetIDs).filter { validIDs.contains($0) }
            if !surviving.isEmpty {
                selectedTargetIDs = surviving
            } else if let firstID = mediaPlayers.first?.entityID {
                selectedTargetIDs = [firstID]
            } else {
                selectedTargetIDs = []
            }
            persist()
        } catch {
            deviceError = error.localizedDescription
        }
    }

    func sendComposerMessage(
        text: String,
        mode: ComposerMode,
        repeatCount: Int,
        repeatDurationMinutes: Int,
        repeatIntervalSeconds: Int,
        countdownMinutes: Int,
        countdownIntervalMinutes: Int,
        countdownTemplate: String,
        finalMessage: String
    ) {
        let targets = selectedTargets
        guard !targets.isEmpty else { return }
        let voice = selectedVoice
        let interval = max(TimeInterval(repeatIntervalSeconds), 5)

        switch mode {
        case .once:
            Task { await sendMessage(text, targets: targets, voice: voice, kind: .single, detail: nil) }
        case .onceAs:
            let formattedMessage = Self.messageWithSenderName(text, senderName: senderName)
            Task { await sendMessage(formattedMessage, targets: targets, voice: voice, kind: .singleAs, detail: senderDetail) }
        case .repeatCount:
            startRepeat(message: text, targets: targets, voice: voice, interval: interval, limit: .count(max(repeatCount, 1)))
        case .repeatDuration:
            startRepeat(
                message: text,
                targets: targets,
                voice: voice,
                interval: interval,
                limit: .duration(TimeInterval(max(repeatDurationMinutes, 1) * 60))
            )
        case .repeatIndefinitely:
            startRepeat(message: text, targets: targets, voice: voice, interval: interval, limit: .indefinitely)
        case .countdown:
            startCountdown(
                totalDuration: TimeInterval(max(countdownMinutes, 1) * 60),
                interval: TimeInterval(max(countdownIntervalMinutes, 1) * 60),
                targets: targets,
                voice: voice,
                template: countdownTemplate,
                finalMessage: finalMessage
            )
        }
    }

    var senderDetail: String? {
        let trimmedName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : "\(trimmedName) says"
    }

    func updateSenderName(_ name: String) {
        senderName = name
        persist()
    }

    func retry(_ message: MessageRecord) {
        Task {
            await sendMessage(
                message.text,
                targets: message.targets,
                voice: message.voicePreset,
                kind: message.kind,
                detail: message.detail
            )
        }
    }

    func resend(_ message: MessageRecord) {
        Task {
            await sendMessage(
                message.text,
                targets: message.targets,
                voice: message.voicePreset,
                kind: .single,
                detail: "Resent"
            )
        }
    }

    func addOrUpdateVoice(_ preset: VoicePreset) {
        if let index = voicePresets.firstIndex(where: { $0.id == preset.id }) {
            voicePresets[index] = preset
        } else {
            voicePresets.append(preset)
        }
        selectedVoiceID = preset.id
        persist()
    }

    func deleteVoice(_ preset: VoicePreset) {
        guard preset.isCustom else { return }
        voicePresets.removeAll { $0.id == preset.id }
        if selectedVoiceID == preset.id {
            selectedVoiceID = VoicePreset.defaultPreset.id
        }
        persist()
    }

    func clearHistory() {
        messages.removeAll()
        persist()
    }

    func stopRepeat(_ session: RepeatSession) {
        repeatTasks[session.id]?.cancel()
        repeatTasks[session.id] = nil
        let inFlightMessageID = sessionInFlightMessageIDs[session.id]
            ?? repeatSessions.first(where: { $0.id == session.id })?.inFlightMessageID
            ?? session.inFlightMessageID
        sessionInFlightMessageIDs[session.id] = nil
        repeatSessions.removeAll { $0.id == session.id }
        if let inFlightMessageID,
           let index = messages.firstIndex(where: { $0.id == inFlightMessageID && $0.status == .sending }) {
            messages[index].status = .cancelled
            messages[index].errorMessage = nil
            persist()
        }
    }

    func stopCountdown(_ session: CountdownSession) {
        countdownTasks[session.id]?.cancel()
        countdownTasks[session.id] = nil
        let inFlightMessageID = sessionInFlightMessageIDs[session.id]
            ?? countdownSessions.first(where: { $0.id == session.id })?.inFlightMessageID
            ?? session.inFlightMessageID
        sessionInFlightMessageIDs[session.id] = nil
        countdownSessions.removeAll { $0.id == session.id }
        if let inFlightMessageID,
           let index = messages.firstIndex(where: { $0.id == inFlightMessageID && $0.status == .sending }) {
            messages[index].status = .cancelled
            messages[index].errorMessage = nil
            persist()
        }
    }

    func resumeRepeat(_ session: RepeatSession) {
        guard let index = repeatSessions.firstIndex(where: { $0.id == session.id }),
              repeatSessions[index].status.isResumable else { return }

        if shouldCompleteRepeat(session.id) {
            repeatSessions[index].status = .completed
            return
        }

        repeatSessions[index].status = .running
        runRepeatSession(session.id)
    }

    func resumeCountdown(_ session: CountdownSession) {
        guard let index = countdownSessions.firstIndex(where: { $0.id == session.id }),
              countdownSessions[index].status.isResumable else { return }

        let elapsed = now().timeIntervalSince(session.startedAt)
        let overdue = elapsed - session.totalDuration

        if overdue > Self.countdownStalenessCutoff {
            countdownSessions[index].remaining = 0
            countdownSessions[index].status = .expired
            messages.append(
                MessageRecord(
                    id: UUID(),
                    text: session.finalMessage,
                    targets: session.targets,
                    voicePreset: session.voicePreset,
                    sentAt: now(),
                    status: .cancelled,
                    errorMessage: nil,
                    kind: .countdown,
                    detail: "Expired – not announced"
                )
            )
            persist()
            return
        }

        countdownSessions[index].status = .running
        runCountdownSession(session.id)
    }

    func appDidEnterBackground() {
        guard hasRunningSessions else { return }
        backgroundWarning = "Repeats are best-effort while the app is backgrounded. iOS may pause longer sessions."
        beginBackgroundTask()
    }

    func appDidBecomeActive() {
        endBackgroundTask()
    }

    private var hasRunningSessions: Bool {
        repeatSessions.contains { $0.status == .running } || countdownSessions.contains { $0.status == .running }
    }

    @discardableResult
    private func sendMessage(
        _ text: String,
        targets: [MediaPlayerTarget],
        voice: VoicePreset,
        kind: MessageKind,
        detail: String?,
        sessionID: UUID? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !targets.isEmpty else { return false }

        let id = UUID()
        if let sessionID {
            sessionInFlightMessageIDs[sessionID] = id
            updateRepeatSession(sessionID) { $0.inFlightMessageID = id }
            updateCountdownSession(sessionID) { $0.inFlightMessageID = id }
        }
        defer {
            if let sessionID {
                sessionInFlightMessageIDs[sessionID] = nil
                updateRepeatSession(sessionID) { $0.inFlightMessageID = nil }
                updateCountdownSession(sessionID) { $0.inFlightMessageID = nil }
            }
        }

        messages.append(
            MessageRecord(
                id: id,
                text: trimmed,
                targets: targets,
                voicePreset: voice,
                sentAt: now(),
                status: .sending,
                errorMessage: nil,
                kind: kind,
                detail: detail
            )
        )
        persist()

        do {
            try await client.sendTTS(
                serverURL: serverProfile.serverURL,
                token: token,
                message: trimmed,
                targets: targets,
                voicePreset: voice,
                ttsEngines: ttsEngines
            )
            updateMessage(id) {
                if $0.status != .cancelled {
                    $0.status = .sent
                    $0.errorMessage = nil
                }
            }
            return true
        } catch {
            updateMessage(id) {
                guard $0.status == .sending else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    $0.status = .cancelled
                    $0.errorMessage = nil
                } else {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            return false
        }
    }

    func startRepeat(
        message: String,
        targets: [MediaPlayerTarget],
        voice: VoicePreset,
        interval: TimeInterval,
        limit: RepeatLimit
    ) {
        clearInactiveSessions()
        let session = RepeatSession(
            id: UUID(),
            message: message,
            targets: targets,
            voicePreset: voice,
            interval: interval,
            limit: limit,
            startedAt: now(),
            sentCount: 0,
            status: .running
        )
        repeatSessions.insert(session, at: 0)
        runRepeatSession(session.id)
    }

    private func runRepeatSession(_ id: UUID) {
        repeatTasks[id]?.cancel()
        repeatTasks[id] = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let session = self.repeatSessions.first(where: { $0.id == id }) else { return }

                if self.shouldCompleteRepeat(id) {
                    self.updateRepeatSession(id) { $0.status = .completed }
                    break
                }

                let nextCount = session.sentCount + 1
                let detail: String
                switch session.limit {
                case .count(let count):
                    detail = "Repeating \(nextCount)/\(count)"
                case .duration(let duration):
                    detail = "Repeating for \(Int(duration / 60)) min"
                case .indefinitely:
                    detail = "Repeating until stopped"
                }

                let sendSucceeded = await self.sendMessage(
                    session.message,
                    targets: session.targets,
                    voice: session.voicePreset,
                    kind: .repeated,
                    detail: detail,
                    sessionID: id
                )

                if Task.isCancelled {
                    break
                }

                guard sendSucceeded else {
                    self.updateRepeatSession(id) { $0.status = .failed }
                    break
                }

                self.incrementRepeatSession(id)

                if self.shouldCompleteRepeat(id) {
                    self.updateRepeatSession(id) { $0.status = .completed }
                    break
                }

                do {
                    try await self.sleep(session.interval)
                } catch {
                    break
                }
            }
        }
    }

    func startCountdown(
        totalDuration: TimeInterval,
        interval: TimeInterval,
        targets: [MediaPlayerTarget],
        voice: VoicePreset,
        template: String,
        finalMessage: String
    ) {
        clearInactiveSessions()
        let safeTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You have {minutes} minutes until it's time to go."
            : template
        let safeFinal = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "It's time to go."
            : finalMessage

        let session = CountdownSession(
            id: UUID(),
            totalDuration: totalDuration,
            interval: interval,
            targets: targets,
            voicePreset: voice,
            template: safeTemplate,
            finalMessage: safeFinal,
            startedAt: now(),
            remaining: totalDuration,
            status: .running
        )
        countdownSessions.insert(session, at: 0)
        runCountdownSession(session.id)
    }

    private func runCountdownSession(_ id: UUID) {
        countdownTasks[id]?.cancel()
        countdownTasks[id] = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let session = self.countdownSessions.first(where: { $0.id == id }) else { return }
                let deadline = session.startedAt.addingTimeInterval(session.totalDuration)
                let now = self.now()
                let elapsed = now.timeIntervalSince(session.startedAt)
                let remaining = session.totalDuration - elapsed

                if remaining <= 0 {
                    let overdue = now.timeIntervalSince(deadline)
                    if overdue > Self.countdownStalenessCutoff {
                        self.updateCountdownSession(id) {
                            $0.remaining = 0
                            $0.status = .expired
                        }
                        self.messages.append(
                            MessageRecord(
                                id: UUID(),
                                text: session.finalMessage,
                                targets: session.targets,
                                voicePreset: session.voicePreset,
                                sentAt: self.now(),
                                status: .cancelled,
                                errorMessage: nil,
                                kind: .countdown,
                                detail: "Expired – not announced"
                            )
                        )
                        self.persist()
                        break
                    }

                    let sendSucceeded = await self.sendMessage(
                        session.finalMessage,
                        targets: session.targets,
                        voice: session.voicePreset,
                        kind: .countdown,
                        detail: "Final",
                        sessionID: id
                    )

                    if Task.isCancelled {
                        break
                    }

                    self.updateCountdownSession(id) {
                        if sendSucceeded {
                            $0.remaining = 0
                            $0.status = .completed
                        } else {
                            $0.status = .failed
                        }
                    }
                    break
                }

                let dueIndex = Int(elapsed / session.interval)
                if dueIndex >= session.announcedCount {
                    // Counted before sending so an interrupted send isn't replayed on resume.
                    self.updateCountdownSession(id) { $0.announcedCount = dueIndex + 1 }

                    let minutes = max(Int(ceil(remaining / 60)), 0)
                    let message = Self.countdownMessage(template: session.template, remaining: remaining)
                    let sendSucceeded = await self.sendMessage(
                        message,
                        targets: session.targets,
                        voice: session.voicePreset,
                        kind: .countdown,
                        detail: "\(minutes) min remaining",
                        sessionID: id
                    )

                    if Task.isCancelled {
                        break
                    }

                    guard sendSucceeded else {
                        self.updateCountdownSession(id) {
                            $0.announcedCount = session.announcedCount
                            $0.status = .failed
                        }
                        break
                    }

                    self.updateCountdownSession(id) {
                        $0.remaining = max(deadline.timeIntervalSince(self.now()), 0)
                    }
                }

                guard let announcedCount = self.countdownSessions.first(where: { $0.id == id })?.announcedCount else { return }
                let nextIntervalTime = session.startedAt.addingTimeInterval(Double(announcedCount) * session.interval)
                let nextTarget = min(nextIntervalTime, deadline)
                let sleepDuration = max(nextTarget.timeIntervalSince(self.now()), 0)

                do {
                    try await self.sleep(sleepDuration)
                } catch {
                    break
                }
            }
        }
    }

    nonisolated static func countdownMessage(template: String, remaining: TimeInterval) -> String {
        let minutes = max(Int(ceil(remaining / 60)), 0)
        return template.replacingOccurrences(of: "{minutes}", with: "\(minutes)")
    }

    nonisolated static func messageWithSenderName(_ message: String, senderName: String) -> String {
        let trimmedName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return trimmedMessage
        }
        return "\(trimmedName) says: \(trimmedMessage)"
    }

    private func shouldCompleteRepeat(_ id: UUID) -> Bool {
        guard let session = repeatSessions.first(where: { $0.id == id }) else { return true }
        return session.limit.isComplete(sentCount: session.sentCount, elapsed: now().timeIntervalSince(session.startedAt))
    }

    private func incrementRepeatSession(_ id: UUID) {
        updateRepeatSession(id) { $0.sentCount += 1 }
    }

    private func clearInactiveSessions() {
        repeatSessions.removeAll { !$0.status.isActive }
        countdownSessions.removeAll { !$0.status.isActive }
    }

    private func updateMessage(_ id: UUID, _ update: (inout MessageRecord) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
        persist()
    }

    private func updateRepeatSession(_ id: UUID, _ update: (inout RepeatSession) -> Void) {
        guard let index = repeatSessions.firstIndex(where: { $0.id == id }) else { return }
        update(&repeatSessions[index])
    }

    private func updateCountdownSession(_ id: UUID, _ update: (inout CountdownSession) -> Void) {
        guard let index = countdownSessions.firstIndex(where: { $0.id == id }) else { return }
        update(&countdownSessions[index])
    }

    func handleBackgroundExpiration() {
        // A send cut off mid-request may already have been announced, so it counts as sent
        // and is marked unknown rather than being replayed on resume.
        for index in repeatSessions.indices where repeatSessions[index].status == .running {
            let session = repeatSessions[index]
            repeatSessions[index].status = .pausedBySystem
            if markInFlightMessageUnknown(sessionID: session.id) {
                repeatSessions[index].sentCount += 1
                if shouldCompleteRepeat(session.id) {
                    repeatSessions[index].status = .completed
                }
            }
        }
        for index in countdownSessions.indices where countdownSessions[index].status == .running {
            let session = countdownSessions[index]
            countdownSessions[index].status = .pausedBySystem
            let deadline = session.startedAt.addingTimeInterval(session.totalDuration)
            if markInFlightMessageUnknown(sessionID: session.id), now() >= deadline {
                countdownSessions[index].remaining = 0
                countdownSessions[index].status = .completed
            }
        }
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
        countdownTasks.values.forEach { $0.cancel() }
        countdownTasks.removeAll()

        backgroundWarning = "iOS paused active repeat work while HA Voice was in the background."
        endBackgroundTask()
    }

    private func markInFlightMessageUnknown(sessionID: UUID) -> Bool {
        guard let messageID = sessionInFlightMessageIDs[sessionID],
               let index = messages.firstIndex(where: { $0.id == messageID && $0.status == .sending }) else {
            return false
        }
        messages[index].status = .unknown
        messages[index].errorMessage = nil
        persist()
        return true
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HA Voice repeat session") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleBackgroundExpiration()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func load() {
        token = keychain.readToken()

        guard let data = defaults.data(forKey: Self.persistedStateKey) else {
            return
        }

        do {
            let state = try JSONDecoder().decode(PersistedAppState.self, from: data)
            serverProfile = state.serverProfile
            senderName = state.senderName
            selectedTargetIDs = state.selectedTargetIDs
            selectedVoiceID = state.selectedVoiceID
            mediaPlayers = state.mediaPlayers
            ttsEngines = state.ttsEngines
            voicePresets = Self.presetsByAddingMissingBuiltIns(to: state.voicePresets)
            messages = state.messages
        } catch {
            Logger.persistence.error("Failed to decode persisted state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func presetsByAddingMissingBuiltIns(to savedPresets: [VoicePreset]) -> [VoicePreset] {
        var presets = savedPresets.isEmpty ? VoicePreset.builtIns : savedPresets
        for builtIn in VoicePreset.builtIns where !presets.contains(where: { $0.id == builtIn.id }) {
            presets.append(builtIn)
        }
        return presets
    }

    private func persist() {
        let state = PersistedAppState(
            serverProfile: serverProfile,
            senderName: senderName,
            selectedTargetIDs: selectedTargetIDs,
            selectedVoiceID: selectedVoiceID,
            mediaPlayers: mediaPlayers,
            ttsEngines: ttsEngines,
            voicePresets: voicePresets,
            messages: Array(messages.suffix(200))
        )
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.persistedStateKey)
        } catch {
            Logger.persistence.error("Failed to encode persisted state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let persistedStateKey = "haVoice.persistedState"
}
