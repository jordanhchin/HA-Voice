import SwiftUI

struct VoicePresetListView: View {
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
