import Observation
import PlexKit
import SwiftUI

/// The one model and player, shared by every scene. The phone window and
/// the CarPlay scene are peers: either can be the first to connect, and a
/// car can launch the app with the phone locked and no window at all. So
/// the wiring that used to hang off `ContentView` (bootstrap, the player's
/// rediscovery hook, the library hand-off, stopping on sign-out) lives here,
/// where it runs whichever scene comes up.
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let model: AppModel
    let player: AudioPlayer

    private init() {
        // One cache with two roots, shared by the player (window prefetch)
        // and the offline store (pins), so a single pump decides what
        // downloads next.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ctunes/Offline")
        let cache = TrackCache(
            directory: caches.appending(path: "Tracks"),
            pinnedDirectory: support.appending(path: "Tracks"),
            limit: AudioPlayer.storedCacheLimit,
            session: AudioPlayer.downloadSession()
        )
        let store = OfflineStore(directory: support, cache: cache)
        player = AudioPlayer(cache: cache)
        model = AppModel(offline: store, cache: cache)

        // The player's stream failures go through the same rediscovery as
        // a browse fetch. The library is handed over here, before the
        // player reloads, rather than left to the observation below.
        player.connectionLost = { [model, player] error in
            let recovered = await model.connectionLost(error)
            player.adopt(model.library)
            return recovered
        }
        followModel()
        Task { await model.bootstrap() }
    }

    /// A queue that started offline reports timelines once the server is
    /// back, and one that started online keeps playing pinned files. And
    /// sign-out lives in the model, which doesn't know the player: stop
    /// playback and drop the cached audio when it happens.
    private func followModel() {
        let model = model, player = player
        Task { @MainActor in
            var generation = model.libraryGeneration
            var state = model.state
            for await current in Observations({ (state: model.state, generation: model.libraryGeneration) }) {
                if current.generation != generation {
                    generation = current.generation
                    player.adopt(model.library)
                }
                if current.state != state {
                    let signedOut = current.state == .signedOut
                        && (state == .signedIn || state == .offline || state == .reconnecting)
                    state = current.state
                    if signedOut { await player.signOut() }
                }
            }
        }
    }
}
