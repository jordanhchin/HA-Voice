import SwiftUI

struct MainMessagingView: View {
    @Bindable var appState: AppState
    @Binding var mode: ComposerMode

    @State private var message = ""
    @State private var repeatCount = 3
    @State private var repeatDurationMinutes = 5
    @State private var repeatIntervalSeconds = 60
    @State private var countdownMinutes = 10
    @State private var countdownIntervalMinutes = 1
    @State private var countdownTemplate = "You have {minutes} minutes until it's time to go."
    @State private var finalMessage = "It's time to go."

    var body: some View {
        VStack(spacing: 0) {
            if let warning = appState.backgroundWarning {
                BannerView(text: warning, systemImage: "clock.badge.exclamationmark")
            }

            if appState.hasActiveSessions {
                ActiveSessionsView(appState: appState)
            }

            MessageHistoryView(appState: appState)

            ComposerView(
                appState: appState,
                message: $message,
                mode: $mode,
                repeatCount: $repeatCount,
                repeatDurationMinutes: $repeatDurationMinutes,
                repeatIntervalSeconds: $repeatIntervalSeconds,
                countdownMinutes: $countdownMinutes,
                countdownIntervalMinutes: $countdownIntervalMinutes,
                countdownTemplate: $countdownTemplate,
                finalMessage: $finalMessage,
                send: send
            )
        }
        .background(Color(.systemGroupedBackground))
    }

    private func send() {
        appState.sendComposerMessage(
            text: message,
            mode: mode,
            repeatCount: repeatCount,
            repeatDurationMinutes: repeatDurationMinutes,
            repeatIntervalSeconds: repeatIntervalSeconds,
            countdownMinutes: countdownMinutes,
            countdownIntervalMinutes: countdownIntervalMinutes,
            countdownTemplate: countdownTemplate,
            finalMessage: finalMessage
        )
        if mode == .once || mode == .onceAs || mode == .repeatCount || mode == .repeatDuration || mode == .repeatIndefinitely {
            message = ""
        }
    }
}

private struct BannerView: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.yellow.opacity(0.2))
    }
}
