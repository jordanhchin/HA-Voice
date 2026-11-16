import SwiftUI

struct SavedPhrasesManageView: View {
    @Bindable var appState: AppState
    @State private var renamingPhrase: SavedPhrase?
    @State private var renameText = ""

    var body: some View {
        Group {
            if appState.savedPhrases.isEmpty {
                ContentUnavailableView(
                    "No Saved Phrases",
                    systemImage: "bookmark",
                    description: Text("Tap the bookmark button in the composer to save a phrase for quick reuse.")
                )
            } else {
                List {
                    ForEach(appState.savedPhrases) { phrase in
                        Button {
                            renameText = phrase.name
                            renamingPhrase = phrase
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(phrase.name)
                                        .font(.body)
                                    Text(phrase.summary(mediaPlayers: appState.mediaPlayers, voicePresets: appState.voicePresets))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if appState.hasUnavailableTargetOrVoice(for: phrase) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Unavailable speaker or voice")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { source, destination in
                        appState.movePhrases(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        appState.deletePhrases(at: offsets)
                    }
                }
            }
        }
        .navigationTitle("Saved Phrases")
        .toolbar {
            if !appState.savedPhrases.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .alert(
            "Rename Phrase",
            isPresented: Binding(
                get: { renamingPhrase != nil },
                set: { if !$0 { renamingPhrase = nil } }
            )
        ) {
            TextField("Phrase name", text: $renameText)
            Button("Save") {
                if let phrase = renamingPhrase {
                    appState.renamePhrase(phrase, to: renameText)
                }
                renamingPhrase = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                renamingPhrase = nil
            }
        }
    }
}
