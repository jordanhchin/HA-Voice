import SwiftUI

struct ActiveSessionsView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(appState.activeRepeatSessions) { session in
                    SessionPill(
                        title: session.summary,
                        status: session.status,
                        resume: { appState.resumeRepeat(session) },
                        stop: { appState.stopRepeat(session) }
                    )
                }

                ForEach(appState.activeCountdownSessions) { session in
                    SessionPill(
                        title: session.summary,
                        status: session.status,
                        resume: { appState.resumeCountdown(session) },
                        stop: { appState.stopCountdown(session) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }
}

private struct SessionPill: View {
    let title: String
    let status: SessionStatus
    var resume: (() -> Void)? = nil
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
            }
            if status.isResumable, let resume {
                Button("Resume", action: resume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var iconName: String {
        switch status {
        case .running: "dot.radiowaves.left.and.right"
        case .pausedBySystem: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch status {
        case .running: .accentColor
        case .pausedBySystem: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var displayTitle: String {
        switch status {
        case .pausedBySystem:
            return "Paused (\(title))"
        case .failed:
            return "Failed (\(title))"
        default:
            return title
        }
    }
}
