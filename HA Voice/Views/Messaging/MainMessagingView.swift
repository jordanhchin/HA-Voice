import SwiftUI

struct MainMessagingView: View {
    @Bindable var appState: AppState
    @Binding var draft: ComposerDraft

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
                draft: $draft,
                send: send
            )
        }
        .background(Color(.systemGroupedBackground))
    }

    private func send() {
        appState.sendComposerMessage(draft)
        if draft.mode == .once || draft.mode == .onceAs || draft.mode == .repeatCount || draft.mode == .repeatDuration || draft.mode == .repeatIndefinitely {
            draft.message = ""
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
