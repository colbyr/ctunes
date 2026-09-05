import SwiftUI

struct AuthView: View {
    let model: AppModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 20) {
            // The icon asset itself, since the AppIcon set isn't loadable by name.
            Image("AppIconArt")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 22))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            Text("Tunes")
                .font(.largeTitle.bold())

            if case .linking(let code) = model.state {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for approval")
                        .font(.subheadline)
                    Text(code)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else {
                Button("Sign in with Plex") {
                    Task { await model.signIn(using: webAuthenticationSession) }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Color.accentInk)
                .controlSize(.large)
                .padding(.top, 8)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
}
