import SwiftUI

struct ConnectionProgressSheet: View {
    let isWorking: Bool
    let succeeded: Bool
    let progressMessage: String
    let resultMessage: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                Text("Testing Connection")
                    .font(.headline)
            } else {
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(succeeded ? .green : .orange)
                Text(succeeded ? "Saved" : "Connection Failed")
                    .font(.headline)
            }

            Text(resultMessage ?? progressMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            if !isWorking {
                Button("Done", action: dismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }
}
