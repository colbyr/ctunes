import PlexKit
import SwiftUI

struct ContentView: View {
    @State private var model: AppModel
    @State private var player: AudioPlayer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // One cache with two roots, shared by the player (window prefetch)
        // and the offline store (pins), so a single pump decides what
        // downloads next.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ctunes/Offline")
        let cache = TrackCache(
            directory: caches.appending(path: "Tracks"),
            pinnedDirectory: support.appending(path: "Tracks"),
            session: AudioPlayer.downloadSession()
        )
        let store = OfflineStore(directory: support, cache: cache)
        _player = State(initialValue: AudioPlayer(cache: cache))
        _model = State(initialValue: AppModel(offline: store, cache: cache))
    }

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
            case .signedIn, .offline:
                LibraryView(model: model)
            }
        }
        .environment(player)
        .task { await model.bootstrap() }
        // Sign-out lives in the model, which doesn't know the player; stop
        // playback and drop the cached audio here when it happens.
        .onChange(of: model.state) { old, new in
            guard old == .signedIn || old == .offline, new == .signedOut else { return }
            Task { await player.signOut() }
        }
        // A queue that started offline reports timelines once the server is
        // back, and one that started online keeps playing pinned files.
        .onChange(of: model.libraryGeneration) {
            player.adopt(model.library)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
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
                .buttonStyle(.borderedProminent)
            Button("Sign out") { Task { await model.signOut() } }
        }
    }
}

#Preview {
    ContentView()
}
