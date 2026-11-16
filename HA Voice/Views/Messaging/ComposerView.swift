import SwiftUI

struct ComposerView: View {
    @Bindable var appState: AppState
    @Binding var message: String
    @Binding var mode: ComposerMode
    @Binding var repeatCount: Int
    @Binding var repeatDurationMinutes: Int
    @Binding var repeatIntervalSeconds: Int
    @Binding var countdownMinutes: Int
    @Binding var countdownIntervalMinutes: Int
    @Binding var countdownTemplate: String
    @Binding var finalMessage: String
    let send: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ModeControlsPanel(
                mode: mode,
                repeatCount: $repeatCount,
                repeatDurationMinutes: $repeatDurationMinutes,
                repeatIntervalSeconds: $repeatIntervalSeconds,
                countdownMinutes: $countdownMinutes,
                countdownIntervalMinutes: $countdownIntervalMinutes,
                countdownTemplate: $countdownTemplate,
                finalMessage: $finalMessage,
                senderName: appState.senderName
            )

            if mode == .countdown {
                Button(action: send) {
                    Label("Start Countdown", systemImage: sendIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sendDisabled)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Message", text: $message, axis: .vertical)
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
                    .accessibilityLabel(mode == .once || mode == .onceAs ? "Send message" : "Start")
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var sendIcon: String {
        mode == .once || mode == .onceAs ? "paperplane.fill" : "play.fill"
    }

    private var sendDisabled: Bool {
        appState.selectedTarget == nil ||
        (mode != .countdown && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
        (mode == .onceAs && appState.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    let mode: ComposerMode
    @Binding var repeatCount: Int
    @Binding var repeatDurationMinutes: Int
    @Binding var repeatIntervalSeconds: Int
    @Binding var countdownMinutes: Int
    @Binding var countdownIntervalMinutes: Int
    @Binding var countdownTemplate: String
    @Binding var finalMessage: String
    let senderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactModeSummary(
                iconName: mode.iconName,
                title: summaryTitle,
                subtitle: summarySubtitle
            )

            switch mode {
            case .once:
                EmptyView()
            case .onceAs:
                EmptyView()
            case .repeatCount:
                Stepper("Repeat \(repeatCount) times", value: $repeatCount, in: 1...100)
                intervalStepper
            case .repeatDuration:
                Stepper("Repeat for \(repeatDurationMinutes) min", value: $repeatDurationMinutes, in: 1...180)
                intervalStepper
            case .repeatIndefinitely:
                intervalStepper
            case .countdown:
                Stepper("Countdown \(countdownMinutes) min", value: $countdownMinutes, in: 1...240)
                Stepper("Speak every \(countdownIntervalMinutes) min", value: $countdownIntervalMinutes, in: 1...60)
                TextField("Countdown message template", text: $countdownTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                TextField("Final message", text: $finalMessage)
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
        Stepper("Every \(repeatIntervalSeconds) sec", value: $repeatIntervalSeconds, in: 5...3600, step: 5)
    }

    private var senderDisplayName: String {
        let trimmedName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Name" : trimmedName
    }

    private var summaryTitle: String {
        switch mode {
        case .once:
            "Send once"
        case .onceAs:
            "Send once as \(senderDisplayName)"
        case .repeatCount:
            "Repeat \(repeatCount) times"
        case .repeatDuration:
            "Repeat for \(repeatDurationMinutes) min"
        case .repeatIndefinitely:
            "Repeat until stopped"
        case .countdown:
            "Countdown \(countdownMinutes) min"
        }
    }

    private var summarySubtitle: String {
        switch mode {
        case .once:
            "Message is spoken exactly as written."
        case .onceAs:
            senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Set Name in Settings to add a sender prefix."
            : "Prepends \"\(senderDisplayName) says:\" before speaking."
        case .repeatCount:
            "Speaks the message \(repeatCount) times, every \(repeatIntervalSeconds) sec."
        case .repeatDuration:
            "Keeps speaking for \(repeatDurationMinutes) min, every \(repeatIntervalSeconds) sec."
        case .repeatIndefinitely:
            "Runs until stopped. Background delivery is best-effort."
        case .countdown:
            "Speaks remaining time every \(countdownIntervalMinutes) min, then the final message."
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
