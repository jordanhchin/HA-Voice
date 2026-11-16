import SwiftUI

struct SetupView: View {
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
                Text("Defaults to https://. Local servers without SSL usually need http://.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
