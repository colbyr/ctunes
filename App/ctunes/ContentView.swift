import PlexKit
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut, .linking:
                AuthView(model: model)
            case .signedIn:
                SignedInView(model: model)
            }
        }
        .task { await model.bootstrap() }
    }
}

/// Placeholder until M3 replaces this with the library browser.
struct SignedInView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Signed in to Plex")
                .font(.title2.bold())
            Text("Library browsing lands in M3.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Sign out") {
                Task { await model.signOut() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
