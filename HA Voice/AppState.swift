import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppState {
    var serverProfile = ServerProfile()
    var senderName = ""
    var token = ""
    var mediaPlayers: [MediaPlayerTarget] = []
    var selectedTargetID: String?
    var voicePresets: [VoicePreset] = VoicePreset.builtIns
    var selectedVoiceID: UUID = VoicePreset.defaultPreset.id
    var messages: [MessageRecord] = []
    var repeatSessions: [RepeatSession] = []
    var countdownSessions: [CountdownSession] = []
    var isRefreshingDevices = false
    var setupError: String?
    var deviceError: String?
    var backgroundWarning: String?

    private let client: HomeAssistantClient
    private let keychain: KeychainTokenStore
    private let defaults: UserDefaults
    private var repeatTasks: [UUID: Task<Void, Never>] = [:]
    private var countdownTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(client: HomeAssistantClient, keychain: KeychainTokenStore, defaults: UserDefaults) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        load()
    }

    convenience init() {
        self.init(client: HomeAssistantClient(), keychain: KeychainTokenStore(), defaults: .standard)
    }

    var hasServerConfiguration: Bool {
        !serverProfile.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && HomeAssistantClient.isValidToken(token)
    }

    var selectedTarget: MediaPlayerTarget? {
        get {
            mediaPlayers.first { $0.entityID == selectedTargetID } ?? mediaPlayers.first
        }
        set {
            selectedTargetID = newValue?.entityID
            persist()
        }
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
        repeatSessions.filter { $0.status == .running }
    }

    var activeCountdownSessions: [CountdownSession] {
        countdownSessions.filter { $0.status == .running }
    }

    var hasActiveSessions: Bool {
        !activeRepeatSessions.isEmpty || !activeCountdownSessions.isEmpty
    }

    func saveServer(serverURL: String, token: String, progress: ((String) -> Void)? = nil) async -> Bool {
        let previousProfile = serverProfile
        let previousToken = self.token
        let hadExistingConfiguration = hasServerConfiguration

        progress?("Saving access token")
        serverProfile.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try keychain.saveToken(self.token)
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
            setupError = error.localizedDescription
            persist()
            progress?("Connection failed")
            return false
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
            mediaPlayers = try await client.fetchMediaPlayers(serverURL: serverProfile.serverURL, token: token)
            if selectedTargetID == nil || !mediaPlayers.contains(where: { $0.entityID == selectedTargetID }) {
                selectedTargetID = mediaPlayers.first?.entityID
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
        guard let target = selectedTarget else { return }
        let voice = selectedVoice
        let interval = max(TimeInterval(repeatIntervalSeconds), 5)

        switch mode {
        case .once:
            Task { await sendMessage(text, target: target, voice: voice, kind: .single, detail: nil) }
        case .onceAs:
            let formattedMessage = Self.messageWithSenderName(text, senderName: senderName)
            Task { await sendMessage(formattedMessage, target: target, voice: voice, kind: .singleAs, detail: senderDetail) }
        case .repeatCount:
            startRepeat(message: text, target: target, voice: voice, interval: interval, limit: .count(max(repeatCount, 1)))
        case .repeatDuration:
            startRepeat(
                message: text,
                target: target,
                voice: voice,
                interval: interval,
                limit: .duration(TimeInterval(max(repeatDurationMinutes, 1) * 60))
            )
        case .repeatIndefinitely:
            startRepeat(message: text, target: target, voice: voice, interval: interval, limit: .indefinitely)
        case .countdown:
            startCountdown(
                totalDuration: TimeInterval(max(countdownMinutes, 1) * 60),
                interval: TimeInterval(max(countdownIntervalMinutes, 1) * 60),
                target: target,
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
                target: message.target,
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
                target: message.target,
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
        repeatSessions.removeAll { $0.id == session.id }
    }

    func stopCountdown(_ session: CountdownSession) {
        countdownTasks[session.id]?.cancel()
        countdownTasks[session.id] = nil
        countdownSessions.removeAll { $0.id == session.id }
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

    private func sendMessage(
        _ text: String,
        target: MediaPlayerTarget,
        voice: VoicePreset,
        kind: MessageKind,
        detail: String?
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID()
        messages.append(
            MessageRecord(
                id: id,
                text: trimmed,
                target: target,
                voicePreset: voice,
                sentAt: Date(),
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
                target: target,
                voicePreset: voice
            )
            updateMessage(id) {
                $0.status = .sent
                $0.errorMessage = nil
            }
        } catch {
            updateMessage(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func startRepeat(
        message: String,
        target: MediaPlayerTarget,
        voice: VoicePreset,
        interval: TimeInterval,
        limit: RepeatLimit
    ) {
        clearInactiveSessions()
        let session = RepeatSession(
            id: UUID(),
            message: message,
            target: target,
            voicePreset: voice,
            interval: interval,
            limit: limit,
            startedAt: Date(),
            sentCount: 0,
            status: .running
        )
        repeatSessions.insert(session, at: 0)

        repeatTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            let start = Date()

            while !Task.isCancelled {
                await self.sendMessage(message, target: target, voice: voice, kind: .repeated, detail: session.summary)
                self.incrementRepeatSession(session.id)

                if self.shouldCompleteRepeat(session.id, startedAt: start) {
                    self.updateRepeatSession(session.id) { $0.status = .completed }
                    break
                }

                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func startCountdown(
        totalDuration: TimeInterval,
        interval: TimeInterval,
        target: MediaPlayerTarget,
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
            target: target,
            voicePreset: voice,
            template: safeTemplate,
            finalMessage: safeFinal,
            startedAt: Date(),
            remaining: totalDuration,
            status: .running
        )
        countdownSessions.insert(session, at: 0)

        countdownTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            var remaining = totalDuration

            while !Task.isCancelled && remaining > 0 {
                let message = Self.countdownMessage(template: safeTemplate, remaining: remaining)
                await self.sendMessage(message, target: target, voice: voice, kind: .countdown, detail: "\(Int(ceil(remaining / 60))) min remaining")
                remaining -= interval
                self.updateCountdownSession(session.id) {
                    $0.remaining = max(remaining, 0)
                }
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(interval))
                }
            }

            if !Task.isCancelled {
                await self.sendMessage(safeFinal, target: target, voice: voice, kind: .countdown, detail: "Final")
                self.updateCountdownSession(session.id) {
                    $0.remaining = 0
                    $0.status = .completed
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

    private func shouldCompleteRepeat(_ id: UUID, startedAt: Date) -> Bool {
        guard let session = repeatSessions.first(where: { $0.id == id }) else { return true }
        return session.limit.isComplete(sentCount: session.sentCount, elapsed: Date().timeIntervalSince(startedAt))
    }

    private func incrementRepeatSession(_ id: UUID) {
        updateRepeatSession(id) { $0.sentCount += 1 }
    }

    private func clearInactiveSessions() {
        repeatSessions.removeAll { $0.status != .running }
        countdownSessions.removeAll { $0.status != .running }
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

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HA Voice repeat session") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.repeatSessions.indices.forEach { index in
                    if self.repeatSessions[index].status == .running {
                        self.repeatSessions[index].status = .pausedBySystem
                    }
                }
                self.countdownSessions.indices.forEach { index in
                    if self.countdownSessions[index].status == .running {
                        self.countdownSessions[index].status = .pausedBySystem
                    }
                }
                self.backgroundWarning = "iOS paused active repeat work while HA Voice was in the background."
                self.endBackgroundTask()
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

        guard let data = defaults.data(forKey: Self.persistedStateKey),
              let state = try? JSONDecoder().decode(PersistedAppState.self, from: data)
        else {
            return
        }

        serverProfile = state.serverProfile
        senderName = state.senderName
        selectedTargetID = state.selectedTargetID
        selectedVoiceID = state.selectedVoiceID
        mediaPlayers = state.mediaPlayers
        voicePresets = Self.presetsByAddingMissingBuiltIns(to: state.voicePresets)
        messages = state.messages
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
            selectedTargetID: selectedTargetID,
            selectedVoiceID: selectedVoiceID,
            mediaPlayers: mediaPlayers,
            voicePresets: voicePresets,
            messages: Array(messages.suffix(200))
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.persistedStateKey)
        }
    }

    private static let persistedStateKey = "haVoice.persistedState"
}
