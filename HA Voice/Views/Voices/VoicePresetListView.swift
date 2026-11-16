import SwiftUI

struct VoicePresetListView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState
    @State private var editingPreset: VoicePreset?
    @State private var addingPreset = false

    static func engineDisplayName(for preset: VoicePreset, engines: [TTSEngine]) -> String? {
        guard let engineID = preset.engineID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !engineID.isEmpty else {
            return nil
        }
        if let engine = engines.first(where: { $0.entityID == engineID }) {
            return engine.displayName
        }
        if engineID == VoicePreset.cloudEngineID {
            return "Home Assistant Cloud"
        }
        return engineID
    }

    static func subtitle(for preset: VoicePreset, engines: [TTSEngine]) -> String {
        if let engineName = engineDisplayName(for: preset, engines: engines) {
            if let voice = preset.serviceVoice {
                return "\(engineName) · \(voice)"
            }
            return engineName
        }
        return preset.serviceVoice ?? "Uses Home Assistant default"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.voicePresets) { preset in
                        let isAvailable = appState.isPresetAvailable(preset)
                        Button {
                            appState.selectedVoice = preset
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                    if isAvailable {
                                        Text(Self.subtitle(for: preset, engines: appState.ttsEngines))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Label("Engine unavailable – edit to choose another", systemImage: "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                if appState.selectedVoiceID == preset.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(!isAvailable)
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
                    Text("Automatic uses Home Assistant Cloud when it's available, otherwise the first speech engine on your server. Voice availability can change; custom presets let you update the voice option without changing the app.")
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
            isCustom: true,
            engineID: preset.engineID
        ))
    }

    private var availableEngines: [TTSEngine] {
        var engines = appState.ttsEngines
        if let currentID = preset.engineID,
           !currentID.isEmpty,
           !engines.contains(where: { $0.entityID == currentID }) {
            let fallbackName = currentID == VoicePreset.cloudEngineID ? "Home Assistant Cloud" : currentID
            engines.append(TTSEngine(entityID: currentID, name: fallbackName))
        }
        return engines
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $preset.name)
                Picker("Engine", selection: $preset.engineID) {
                    Text("Automatic").tag(String?.none)
                    ForEach(availableEngines) { engine in
                        Text(engine.displayName).tag(String?.some(engine.entityID))
                    }
                }
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
