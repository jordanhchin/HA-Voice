import SwiftUI

struct SavedPhraseStripView: View {
    @Bindable var appState: AppState
    @Binding var draft: ComposerDraft
    let onApplyResult: (PhraseApplyResult) -> Void

    @State private var renamingPhrase: SavedPhrase?
    @State private var renameText = ""
    @State private var deletingPhrase: SavedPhrase?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appState.savedPhrases) { phrase in
                        Button {
                            let result = appState.apply(phrase)
                            draft = phrase.draft
                            onApplyResult(result)
                        } label: {
                            HStack(spacing: 5) {
                                if let iconName = phrase.stripIconName {
                                    Image(systemName: iconName)
                                }
                                Text(phrase.name)
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(phrase.chipAccessibilityLabel)
                        .contextMenu {
                            Button {
                                renameText = phrase.name
                                renamingPhrase = phrase
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button {
                                appState.updatePhrase(phrase, with: draft)
                            } label: {
                                Label("Update with current composer", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(!SavedPhrase.canSave(draft: draft))

                            Button(role: .destructive) {
                                deletingPhrase = phrase
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()
        }
        .background(.regularMaterial)
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
        .alert(
            "Delete Phrase?",
            isPresented: Binding(
                get: { deletingPhrase != nil },
                set: { if !$0 { deletingPhrase = nil } }
            ),
            presenting: deletingPhrase
        ) { phrase in
            Button("Delete", role: .destructive) {
                appState.deletePhrase(phrase)
                deletingPhrase = nil
            }
            Button("Cancel", role: .cancel) {
                deletingPhrase = nil
            }
        } message: { phrase in
            Text("Remove \"\(phrase.name)\" from your saved phrases?")
        }
    }
}
