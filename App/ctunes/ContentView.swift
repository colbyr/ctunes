import PlexKit
import SwiftUI

/// M0 smoke screen: proves the app links PlexKit and can mint and persist a
/// stable client identifier in the keychain. Replaced by AuthView in M1.
struct ContentView: View {
    @State private var identity: Result<PlexIdentity, Error>?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("ctunes")
                .font(.largeTitle.bold())

            switch identity {
            case .success(let identity):
                LabeledContent("Product", value: identity.product)
                LabeledContent("Client ID", value: String(identity.clientIdentifier.prefix(8)))
                Text("Keychain reachable, PlexKit linked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failure(let error):
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            case nil:
                ProgressView()
            }
        }
        .padding()
        .task {
            identity = Result { try PlexIdentity.persistent() }
        }
    }
}

#Preview {
    ContentView()
}
