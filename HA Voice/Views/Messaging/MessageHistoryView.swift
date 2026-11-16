import SwiftUI

struct MessageHistoryView: View {
    @Bindable var appState: AppState
    @State private var isScrolledToLatest = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if appState.messages.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "text.bubble",
                            description: Text("Send a spoken message to start the history.")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(appState.messages) { message in
                            MessageBubbleView(record: message) {
                                appState.retry(message)
                            } resend: {
                                appState.resend(message)
                            }
                            .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom <= 80
            } action: { _, isAtBottom in
                isScrolledToLatest = isAtBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if let lastMessage = appState.messages.last, !isScrolledToLatest {
                    Button {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                        isScrolledToLatest = true
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .shadow(radius: 8, y: 3)
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Jump to latest message")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isScrolledToLatest)
            .onChange(of: appState.messages.count) {
                if let last = appState.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    isScrolledToLatest = true
                }
            }
        }
    }
}

private struct MessageBubbleView: View {
    let record: MessageRecord
    let retry: () -> Void
    let resend: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(record.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: resend) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .accessibilityLabel("Resend message")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Label(record.targetsDisplayName, systemImage: "speaker.wave.2.fill")
                    Label(record.voicePreset.name, systemImage: "waveform")
                    if let detail = record.detail {
                        Label(detail, systemImage: record.kind == .countdown ? "timer" : "repeat")
                    }
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if record.status == .failed {
                    if let error = record.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Retry", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var statusText: String {
        switch record.status {
        case .sending: "Sending"
        case .sent: "Sent \(record.sentAt.formatted(date: .omitted, time: .shortened))"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "May have been announced"
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .sending: "paperplane"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .failed: .red
        case .sent: .green
        default: .secondary
        }
    }
}
