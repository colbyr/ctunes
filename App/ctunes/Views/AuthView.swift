import SwiftUI

struct AuthView: View {
    let model: AppModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentText)

            Text("ctunes")
                .font(.largeTitle.bold())

            Text("Play your Plex music library.")
                .foregroundStyle(.secondary)

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
