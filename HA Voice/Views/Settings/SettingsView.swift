import SwiftUI

struct SettingsView: View {
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
                    Text("Defaults to https://. Local servers without SSL usually need http://.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
