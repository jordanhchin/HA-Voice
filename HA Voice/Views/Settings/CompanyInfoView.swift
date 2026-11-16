import SwiftUI

struct CompanyInfoView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("WaverlyWorksLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .accessibilityLabel("Waverly Works logo")

            Text("Waverly Works")
                .font(.headline)

            VStack(spacing: 4) {
                Link("waverlyworks.net", destination: URL(string: "https://waverlyworks.net")!)
                Link("waverlyworks.net@gmail.com", destination: URL(string: "mailto:waverlyworks.net@gmail.com")!)
            }
            .font(.footnote)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}
