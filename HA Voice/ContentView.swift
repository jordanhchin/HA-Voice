import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()
    @State private var mode: ComposerMode = .once
    @State private var showingDevices = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if appState.hasServerConfiguration {
                MainMessagingView(
                    appState: appState,
                    mode: $mode
                )
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        AppTitleView()
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ModeMenuButton(mode: $mode)

                        Button {
                            showingDevices = true
                        } label: {
                            Label("Speakers", systemImage: "speaker.wave.2")
                        }

                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            } else {
                SetupView(appState: appState)
            }
        }
        .sheet(isPresented: $showingDevices) {
            DevicePickerView(appState: appState)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(appState: appState)
        }
        .task {
            if appState.hasServerConfiguration && appState.mediaPlayers.isEmpty {
                await appState.refreshMediaPlayers()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                appState.appDidEnterBackground()
            case .active:
                appState.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

private struct AppTitleView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            Text("HA Voice")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("HA Voice")
    }
}

private struct MainMessagingView: View {
    @Bindable var appState: AppState
    @Binding var mode: ComposerMode

    @State private var message = ""
    @State private var repeatCount = 3
    @State private var repeatDurationMinutes = 5
    @State private var repeatIntervalSeconds = 60
    @State private var countdownMinutes = 10
    @State private var countdownIntervalMinutes = 1
    @State private var countdownTemplate = "You have {minutes} minutes until it's time to go."
    @State private var finalMessage = "It's time to go."

    var body: some View {
        VStack(spacing: 0) {
            if let warning = appState.backgroundWarning {
                BannerView(text: warning, systemImage: "clock.badge.exclamationmark")
            }

            if appState.hasActiveSessions {
                ActiveSessionsView(appState: appState)
            }

            MessageHistoryView(appState: appState)

            ComposerView(
                appState: appState,
                message: $message,
                mode: $mode,
                repeatCount: $repeatCount,
                repeatDurationMinutes: $repeatDurationMinutes,
                repeatIntervalSeconds: $repeatIntervalSeconds,
                countdownMinutes: $countdownMinutes,
                countdownIntervalMinutes: $countdownIntervalMinutes,
                countdownTemplate: $countdownTemplate,
                finalMessage: $finalMessage,
                send: send
            )
        }
        .background(Color(.systemGroupedBackground))
    }

    private func send() {
        appState.sendComposerMessage(
            text: message,
            mode: mode,
            repeatCount: repeatCount,
            repeatDurationMinutes: repeatDurationMinutes,
            repeatIntervalSeconds: repeatIntervalSeconds,
            countdownMinutes: countdownMinutes,
            countdownIntervalMinutes: countdownIntervalMinutes,
            countdownTemplate: countdownTemplate,
            finalMessage: finalMessage
        )
        if mode == .once || mode == .onceAs || mode == .repeatCount || mode == .repeatDuration || mode == .repeatIndefinitely {
            message = ""
        }
    }
}

private struct MessageHistoryView: View {
    @Bindable var appState: AppState
    @State private var isScrolledToLatest = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if appState.messages.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "text.bubble",
                            description: Text("Send a spoken message to start the history.")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(appState.messages) { message in
                            MessageBubbleView(record: message) {
                                appState.retry(message)
                            } resend: {
                                appState.resend(message)
                            }
                            .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom <= 80
            } action: { _, isAtBottom in
                isScrolledToLatest = isAtBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if let lastMessage = appState.messages.last, !isScrolledToLatest {
                    Button {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                        isScrolledToLatest = true
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .shadow(radius: 8, y: 3)
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Jump to latest message")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isScrolledToLatest)
            .onChange(of: appState.messages.count) {
                if let last = appState.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    isScrolledToLatest = true
                }
            }
        }
    }
}

private struct MessageBubbleView: View {
    let record: MessageRecord
    let retry: () -> Void
    let resend: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(record.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: resend) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .accessibilityLabel("Resend message")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Label(record.target.displayName, systemImage: "speaker.wave.2.fill")
                    Label(record.voicePreset.name, systemImage: "waveform")
                    if let detail = record.detail {
                        Label(detail, systemImage: record.kind == .countdown ? "timer" : "repeat")
                    }
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if record.status == .failed {
                    if let error = record.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Retry", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var statusText: String {
        switch record.status {
        case .sending: "Sending"
        case .sent: "Sent \(record.sentAt.formatted(date: .omitted, time: .shortened))"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .sending: "paperplane"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .failed: .red
        case .sent: .green
        default: .secondary
        }
    }
}

private struct ComposerView: View {
    @Bindable var appState: AppState
    @Binding var message: String
    @Binding var mode: ComposerMode
    @Binding var repeatCount: Int
    @Binding var repeatDurationMinutes: Int
    @Binding var repeatIntervalSeconds: Int
    @Binding var countdownMinutes: Int
    @Binding var countdownIntervalMinutes: Int
    @Binding var countdownTemplate: String
    @Binding var finalMessage: String
    let send: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ModeControlsPanel(
                mode: mode,
                repeatCount: $repeatCount,
                repeatDurationMinutes: $repeatDurationMinutes,
                repeatIntervalSeconds: $repeatIntervalSeconds,
                countdownMinutes: $countdownMinutes,
                countdownIntervalMinutes: $countdownIntervalMinutes,
                countdownTemplate: $countdownTemplate,
                finalMessage: $finalMessage,
                senderName: appState.senderName
            )

            if mode == .countdown {
                Button(action: send) {
                    Label("Start Countdown", systemImage: sendIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sendDisabled)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Message", text: $message, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)

                    Button(action: send) {
                        Image(systemName: sendIcon)
                            .font(.title3.weight(.semibold))
                            .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(sendDisabled)
                    .accessibilityLabel(mode == .once || mode == .onceAs ? "Send message" : "Start")
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var sendIcon: String {
        mode == .once || mode == .onceAs ? "paperplane.fill" : "play.fill"
    }

    private var sendDisabled: Bool {
        appState.selectedTarget == nil ||
        (mode != .countdown && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
        (mode == .onceAs && appState.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct ModeMenuButton: View {
    @Binding var mode: ComposerMode

    var body: some View {
        Menu {
            ForEach(ComposerMode.allCases) { modeOption in
                Button {
                    mode = modeOption
                } label: {
                    Label(modeOption.title, systemImage: modeOption == mode ? "checkmark" : modeOption.iconName)
                }
            }
        } label: {
            Label(mode.title, systemImage: mode.iconName)
        }
        .accessibilityLabel("Message type")
    }
}

private struct ModeControlsPanel: View {
    let mode: ComposerMode
    @Binding var repeatCount: Int
    @Binding var repeatDurationMinutes: Int
    @Binding var repeatIntervalSeconds: Int
    @Binding var countdownMinutes: Int
    @Binding var countdownIntervalMinutes: Int
    @Binding var countdownTemplate: String
    @Binding var finalMessage: String
    let senderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactModeSummary(
                iconName: mode.iconName,
                title: summaryTitle,
                subtitle: summarySubtitle
            )

            switch mode {
            case .once:
                EmptyView()
            case .onceAs:
                EmptyView()
            case .repeatCount:
                Stepper("Repeat \(repeatCount) times", value: $repeatCount, in: 1...100)
                intervalStepper
            case .repeatDuration:
                Stepper("Repeat for \(repeatDurationMinutes) min", value: $repeatDurationMinutes, in: 1...180)
                intervalStepper
            case .repeatIndefinitely:
                intervalStepper
            case .countdown:
                Stepper("Countdown \(countdownMinutes) min", value: $countdownMinutes, in: 1...240)
                Stepper("Speak every \(countdownIntervalMinutes) min", value: $countdownIntervalMinutes, in: 1...60)
                TextField("Countdown message template", text: $countdownTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                TextField("Final message", text: $finalMessage)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var intervalStepper: some View {
        Stepper("Every \(repeatIntervalSeconds) sec", value: $repeatIntervalSeconds, in: 5...3600, step: 5)
    }

    private var senderDisplayName: String {
        let trimmedName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Name" : trimmedName
    }

    private var summaryTitle: String {
        switch mode {
        case .once:
            "Send once"
        case .onceAs:
            "Send once as \(senderDisplayName)"
        case .repeatCount:
            "Repeat \(repeatCount) times"
        case .repeatDuration:
            "Repeat for \(repeatDurationMinutes) min"
        case .repeatIndefinitely:
            "Repeat until stopped"
        case .countdown:
            "Countdown \(countdownMinutes) min"
        }
    }

    private var summarySubtitle: String {
        switch mode {
        case .once:
            "Message is spoken exactly as written."
        case .onceAs:
            senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Set Name in Settings to add a sender prefix."
            : "Prepends \"\(senderDisplayName) says:\" before speaking."
        case .repeatCount:
            "Speaks the message \(repeatCount) times, every \(repeatIntervalSeconds) sec."
        case .repeatDuration:
            "Keeps speaking for \(repeatDurationMinutes) min, every \(repeatIntervalSeconds) sec."
        case .repeatIndefinitely:
            "Runs until stopped. Background delivery is best-effort."
        case .countdown:
            "Speaks remaining time every \(countdownIntervalMinutes) min, then the final message."
        }
    }
}

private struct CompactModeSummary: View {
    let iconName: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ActiveSessionsView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(appState.activeRepeatSessions) { session in
                    SessionPill(title: session.summary, status: session.status) {
                        appState.stopRepeat(session)
                    }
                }

                ForEach(appState.activeCountdownSessions) { session in
                    SessionPill(title: session.summary, status: session.status) {
                        appState.stopCountdown(session)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }
}

private struct SessionPill: View {
    let title: String
    let status: SessionStatus
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status == .running ? "dot.radiowaves.left.and.right" : "checkmark.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if status == .running {
                Button("Stop", action: stop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SetupView: View {
    @Bindable var appState: AppState
    @State private var serverURL = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var showingTokenScanner = false
    @State private var showingConnectionProgress = false
    @State private var connectionProgressMessage = "Starting"
    @State private var connectionResultMessage: String?
    @State private var connectionSucceeded = false

    var body: some View {
        Form {
            Section {
                TextField("https://homeassistant.local:8123", text: $serverURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("Long-lived access token", text: $token)
                if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    Label("Insecure HTTP connection: Token is sent over the network in cleartext.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Home Assistant")
            } footer: {
                Text("Create a long-lived access token from your Home Assistant profile.")
            }

            if let setupError = appState.setupError {
                Section {
                    Label(setupError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    showingTokenScanner = true
                } label: {
                    Label("Scan Token QR Code", systemImage: "qrcode.viewfinder")
                }

                Button {
                    testAndSave()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Test and Save", systemImage: "checkmark.circle")
                    }
                }
                .disabled(serverURL.isEmpty || token.isEmpty || isSaving)
            }
        }
        .navigationTitle("Connect")
        .sheet(isPresented: $showingTokenScanner) {
            QRCodeScannerView { rawValue in
                if let scannedToken = QRTokenParser.token(from: rawValue) {
                    token = scannedToken
                    appState.setupError = nil
                } else {
                    appState.setupError = "Scanned QR code does not contain a valid token."
                }
            }
        }
        .sheet(isPresented: $showingConnectionProgress) {
            ConnectionProgressSheet(
                isWorking: isSaving,
                succeeded: connectionSucceeded,
                progressMessage: connectionProgressMessage,
                resultMessage: connectionResultMessage
            ) {
                showingConnectionProgress = false
            }
        }
        .onAppear {
            serverURL = appState.serverProfile.serverURL
            token = appState.token
        }
    }

    private func testAndSave() {
        showingConnectionProgress = true
        isSaving = true
        connectionSucceeded = false
        connectionResultMessage = nil
        connectionProgressMessage = "Starting"

        Task {
            let succeeded = await appState.saveServer(serverURL: serverURL, token: token) { message in
                connectionProgressMessage = message
            }
            connectionSucceeded = succeeded
            connectionResultMessage = succeeded
                ? "Connected, saved, and loaded media players."
                : appState.setupError ?? "Could not connect to Home Assistant."
            isSaving = false
        }
    }
}

private struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var searchText = ""

    var filteredDevices: [MediaPlayerTarget] {
        guard !searchText.isEmpty else { return appState.mediaPlayers }
        return appState.mediaPlayers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.entityID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = appState.deviceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if filteredDevices.isEmpty {
                    ContentUnavailableView("No Media Players", systemImage: "speaker.slash")
                } else {
                    ForEach(filteredDevices) { device in
                        Button {
                            appState.selectedTarget = device
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                    Text(device.entityID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appState.selectedTargetID == device.entityID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search speakers")
            .navigationTitle("Speakers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshMediaPlayers() }
                    } label: {
                        if appState.isRefreshingDevices {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }
}

private struct VoicePresetListView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var editingPreset: VoicePreset?
    @State private var addingPreset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.voicePresets) { preset in
                        Button {
                            appState.selectedVoice = preset
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                    Text(preset.serviceVoice ?? "Uses Home Assistant default")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appState.selectedVoiceID == preset.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .swipeActions {
                            if preset.isCustom {
                                Button("Delete", role: .destructive) {
                                    appState.deleteVoice(preset)
                                }
                            }
                            Button("Edit") {
                                editingPreset = preset
                            }
                        }
                    }
                } footer: {
                    Text("Home Assistant Cloud voice availability can change. Custom presets let you update the voice option without changing the app.")
                }
            }
            .navigationTitle("Voices")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingPreset = true
                    } label: {
                        Label("Add Voice", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingPreset) { preset in
                VoicePresetEditorView(appState: appState, preset: preset)
            }
            .sheet(isPresented: $addingPreset) {
                VoicePresetEditorView(
                    appState: appState,
                    preset: VoicePreset(id: UUID(), name: "", language: "en-US", voice: "", isCustom: true)
                )
            }
        }
    }
}

private struct VoicePresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var preset: VoicePreset

    init(appState: AppState, preset: VoicePreset) {
        self.appState = appState
        _preset = State(initialValue: VoicePreset(
            id: preset.id,
            name: preset.name,
            language: preset.language,
            voice: preset.voice,
            isCustom: true
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $preset.name)
                TextField("Language", text: $preset.language)
                    .textInputAutocapitalization(.never)
                TextField("Voice option", text: $preset.voice)
                    .textInputAutocapitalization(.never)
            }
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        appState.addOrUpdateVoice(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var serverURL = ""
    @State private var token = ""
    @State private var senderName = ""
    @State private var showingVoices = false
    @State private var showingTokenScanner = false
    @State private var isSaving = false
    @State private var showingConnectionProgress = false
    @State private var connectionProgressMessage = "Starting"
    @State private var connectionResultMessage: String?
    @State private var connectionSucceeded = false
    @State private var showingClearHistoryConfirmation = false

    private var isHTTPConnection: Bool {
        let current = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if current.hasPrefix("http://") { return true }
        if current.isEmpty && appState.serverProfile.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
            return true
        }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Home Assistant") {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Long-lived access token", text: $token)
                    if isHTTPConnection {
                        Label("Insecure HTTP connection: Token is sent over the network in cleartext.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        showingTokenScanner = true
                    } label: {
                        Label("Scan Token QR Code", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        testAndSave()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Test and Save", systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(serverURL.isEmpty || token.isEmpty || isSaving)
                    if let setupError = appState.setupError {
                        Text(setupError)
                            .foregroundStyle(.red)
                    }
                }

                Section("Message Identity") {
                    TextField("Name:", text: $senderName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: senderName) { _, newValue in
                            appState.updateSenderName(newValue)
                        }
                }

                Section("Voice") {
                    Button {
                        showingVoices = true
                    } label: {
                        HStack {
                            Label("Voice", systemImage: "waveform")
                            Spacer()
                            Text(appState.selectedVoice.name)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Repeats") {
                    Text("Repeated and countdown messages keep running while the app is active. In the background, HA Voice requests short extra time, but iOS may pause longer sessions.")
                        .foregroundStyle(.secondary)
                }

                Section("History") {
                    Button("Clear Message History", role: .destructive) {
                        showingClearHistoryConfirmation = true
                    }
                }

                Section("App") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(AppBuildInfo.displayString)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    CompanyInfoView()
                        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                serverURL = appState.serverProfile.serverURL
                token = appState.token
                senderName = appState.senderName
            }
            .sheet(isPresented: $showingVoices) {
                VoicePresetListView(appState: appState)
            }
            .sheet(isPresented: $showingTokenScanner) {
                QRCodeScannerView { rawValue in
                    if let scannedToken = QRTokenParser.token(from: rawValue) {
                        token = scannedToken
                        appState.setupError = nil
                    } else {
                        appState.setupError = "Scanned QR code does not contain a valid token."
                    }
                }
            }
            .sheet(isPresented: $showingConnectionProgress) {
                ConnectionProgressSheet(
                    isWorking: isSaving,
                    succeeded: connectionSucceeded,
                    progressMessage: connectionProgressMessage,
                    resultMessage: connectionResultMessage
                ) {
                    showingConnectionProgress = false
                }
            }
            .alert("Clear Message History?", isPresented: $showingClearHistoryConfirmation) {
                Button("Clear History", role: .destructive) {
                    appState.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all saved message history from this device.")
            }
        }
    }

    private func testAndSave() {
        showingConnectionProgress = true
        isSaving = true
        connectionSucceeded = false
        connectionResultMessage = nil
        connectionProgressMessage = "Starting"

        Task {
            let succeeded = await appState.saveServer(serverURL: serverURL, token: token) { message in
                connectionProgressMessage = message
            }
            connectionSucceeded = succeeded
            connectionResultMessage = succeeded
                ? "Connected, saved, and loaded media players."
                : appState.setupError ?? "Could not connect to Home Assistant."
            isSaving = false
        }
    }
}

private enum AppBuildInfo {
    static var displayString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"
        return "\(version) (\(build))"
    }
}

private struct ConnectionProgressSheet: View {
    let isWorking: Bool
    let succeeded: Bool
    let progressMessage: String
    let resultMessage: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                Text("Testing Connection")
                    .font(.headline)
            } else {
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(succeeded ? .green : .orange)
                Text(succeeded ? "Saved" : "Connection Failed")
                    .font(.headline)
            }

            Text(resultMessage ?? progressMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            if !isWorking {
                Button("Done", action: dismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }
}

private struct CompanyInfoView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("WaverlyWorksLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .accessibilityLabel("Waverly Works logo")

            Text("Waverly Works")
                .font(.headline)

            VStack(spacing: 4) {
                Link("waverlyworks.net", destination: URL(string: "https://waverlyworks.net")!)
                Link("waverlyworks.net@gmail.com", destination: URL(string: "mailto:waverlyworks.net@gmail.com")!)
            }
            .font(.footnote)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

private struct BannerView: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.yellow.opacity(0.2))
    }
}

#Preview {
    ContentView()
}
