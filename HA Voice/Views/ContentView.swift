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
            // Saved state from before engine discovery has speakers but no engines.
            if appState.hasServerConfiguration && (appState.mediaPlayers.isEmpty || appState.ttsEngines.isEmpty) {
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

#Preview {
    ContentView()
}
