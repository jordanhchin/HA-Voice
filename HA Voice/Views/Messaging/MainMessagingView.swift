import SwiftUI

struct MainMessagingView: View {
    @Bindable var appState: AppState
    @Binding var draft: ComposerDraft
    @State private var phraseNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            if let warning = appState.backgroundWarning {
                BannerView(text: warning, systemImage: "clock.badge.exclamationmark")
            }

            if let phraseNotice {
                BannerView(text: phraseNotice, systemImage: "exclamationmark.triangle") {
                    self.phraseNotice = nil
                }
            }

            if appState.hasActiveSessions {
                ActiveSessionsView(appState: appState)
            }

            MessageHistoryView(appState: appState)

            if !appState.savedPhrases.isEmpty {
                SavedPhraseStripView(appState: appState, draft: $draft) { result in
                    phraseNotice = result.noticeMessage
                }
            }

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
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.2))
    }
}
