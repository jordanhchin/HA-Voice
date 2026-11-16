import SwiftUI

struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var searchText = ""
    // Selected-first order is fixed when the picker opens so rows don't jump while tapping.
    @State private var initiallySelectedIDs: Set<String>?

    var sortedDevices: [MediaPlayerTarget] {
        let selectedSet = initiallySelectedIDs ?? Set(appState.selectedTargetIDs)
        let selected = appState.mediaPlayers.filter { selectedSet.contains($0.entityID) }
        let unselected = appState.mediaPlayers.filter { !selectedSet.contains($0.entityID) }
        return selected + unselected
    }

    var filteredDevices: [MediaPlayerTarget] {
        guard !searchText.isEmpty else { return sortedDevices }
        return sortedDevices.filter {
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

                if !appState.mediaPlayers.isEmpty {
                    Section {
                        HStack {
                            Button("Select all") {
                                appState.selectAllTargets()
                            }
                            .buttonStyle(.borderless)
                            .disabled(appState.selectedTargets.count == appState.mediaPlayers.count)

                            Spacer()

                            Button("Clear") {
                                appState.clearTargetSelection()
                            }
                            .buttonStyle(.borderless)
                            .disabled(appState.selectedTargets.count <= 1)
                        }
                    }
                }

                if filteredDevices.isEmpty {
                    ContentUnavailableView("No Media Players", systemImage: "speaker.slash")
                } else {
                    Section {
                        ForEach(filteredDevices) { device in
                            Button {
                                appState.toggleTargetSelection(device)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.displayName)
                                        Text(device.entityID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if appState.isTargetSelected(device) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search speakers")
            .onAppear {
                initiallySelectedIDs = Set(appState.selectedTargetIDs)
            }
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
