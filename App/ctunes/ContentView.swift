import PlexKit
import SwiftUI

struct ContentView: View {
    /// Shared with the CarPlay scene, which may come up first; the model
    /// and player are built and wired there. See `AppRuntime`.
    private let runtime = AppRuntime.shared
    @Environment(\.scenePhase) private var scenePhase

    private var model: AppModel { runtime.model }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut, .linking:
                AuthView(model: model)
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding your server…").foregroundStyle(.secondary)
                }
            case .connectFailed:
                ConnectFailedView(model: model)
            // One label for both: two would be two view identities, and the
            // stack would reset on every transition in or out of offline.
            case .signedIn, .offline, .reconnecting:
                LibraryView(model: model)
            }
        }
        // Filled first: the sign-in and connecting screens are only as big
        // as their text, and the gradient would stop at their edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.ink)
        .background(ParchmentBackground())
        .environment(runtime.player)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshListeners()
            Task {
                switch model.state {
                case .offline: await model.reconnect()
                case .signedIn: await model.resumeDownloads()
                default: break
                }
            }
        }
    }
}

struct ConnectFailedView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach your server", systemImage: "network.slash")
        } description: {
            Text(model.errorMessage ?? "No Plex server answered.")
        } actions: {
            Button("Try again") { Task { await model.connect() } }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Color.accentInk)
            Button("Sign out") { Task { await model.signOut() } }
        }
    }
}

#Preview {
    ContentView()
}
