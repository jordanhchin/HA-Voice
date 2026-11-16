import SwiftUI

struct ComposerView: View {
    @Bindable var appState: AppState
    @Binding var draft: ComposerDraft
    let send: () -> Void

    @State private var showingDevicePicker = false

    static func targetChipText(for targets: [MediaPlayerTarget]) -> String {
        guard let first = targets.first else {
            return "No speaker selected"
        }
        if targets.count == 1 {
            return first.displayName
        }
        return "\(first.displayName) + \(targets.count - 1)"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    showingDevicePicker = true
                } label: {
                    Label(Self.targetChipText(for: appState.selectedTargets), systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Target speakers: \(Self.targetChipText(for: appState.selectedTargets))")

                Spacer()
            }

            ModeControlsPanel(
                draft: $draft,
                senderName: appState.senderName
            )

            if draft.mode == .countdown {
                Button(action: send) {
                    Label("Start Countdown", systemImage: sendIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sendDisabled)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Message", text: $draft.message, axis: .vertical)
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
                    .accessibilityLabel(draft.mode == .once || draft.mode == .onceAs ? "Send message" : "Start")
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerView(appState: appState)
        }
    }

    private var sendIcon: String {
        draft.mode == .once || draft.mode == .onceAs ? "paperplane.fill" : "play.fill"
    }

    private var sendDisabled: Bool {
        appState.selectedTargets.isEmpty ||
        (draft.mode != .countdown && draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
        (draft.mode == .onceAs && appState.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

struct ModeMenuButton: View {
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
    @Binding var draft: ComposerDraft
    let senderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactModeSummary(
                iconName: draft.mode.iconName,
                title: summaryTitle,
                subtitle: summarySubtitle
            )

            switch draft.mode {
            case .once:
                EmptyView()
            case .onceAs:
                EmptyView()
            case .repeatCount:
                Stepper("Repeat \(draft.repeatCount) times", value: $draft.repeatCount, in: 1...100)
                intervalStepper
            case .repeatDuration:
                Stepper("Repeat for \(draft.repeatDurationMinutes) min", value: $draft.repeatDurationMinutes, in: 1...180)
                intervalStepper
            case .repeatIndefinitely:
                intervalStepper
            case .countdown:
                Stepper("Countdown \(draft.countdownMinutes) min", value: $draft.countdownMinutes, in: 1...240)
                Stepper("Speak every \(draft.countdownIntervalMinutes) min", value: $draft.countdownIntervalMinutes, in: 1...60)
                TextField("Countdown message template", text: $draft.countdownTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                TextField("Final message", text: $draft.finalMessage)
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
        Stepper("Every \(draft.repeatIntervalSeconds) sec", value: $draft.repeatIntervalSeconds, in: 5...3600, step: 5)
    }

    private var senderDisplayName: String {
        let trimmedName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Name" : trimmedName
    }

    private var summaryTitle: String {
        switch draft.mode {
        case .once:
            "Send once"
        case .onceAs:
            "Send once as \(senderDisplayName)"
        case .repeatCount:
            "Repeat \(draft.repeatCount) times"
        case .repeatDuration:
            "Repeat for \(draft.repeatDurationMinutes) min"
        case .repeatIndefinitely:
            "Repeat until stopped"
        case .countdown:
            "Countdown \(draft.countdownMinutes) min"
        }
    }

    private var summarySubtitle: String {
        switch draft.mode {
        case .once:
            "Message is spoken exactly as written."
        case .onceAs:
            senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Set Name in Settings to add a sender prefix."
            : "Prepends \"\(senderDisplayName) says:\" before speaking."
        case .repeatCount:
            "Speaks the message \(draft.repeatCount) times, every \(draft.repeatIntervalSeconds) sec."
        case .repeatDuration:
            "Keeps speaking for \(draft.repeatDurationMinutes) min, every \(draft.repeatIntervalSeconds) sec."
        case .repeatIndefinitely:
            "Runs until stopped. Background delivery is best-effort."
        case .countdown:
            "Speaks remaining time every \(draft.countdownIntervalMinutes) min, then the final message."
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
