import SwiftUI

struct DevicePickerView: View {
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
