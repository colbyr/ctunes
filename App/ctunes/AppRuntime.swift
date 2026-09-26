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
    /// The section as the browse root loaded it, read by the search page
    /// and Siri's value query; here rather than on `LibraryView` because
    /// an intent can fire with no window and has to fill it itself.
    let catalog = LibraryCatalog()
    /// A `ctunes://` URL's route, parked until the library stack is up.
    let links = DeepLinks()

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
        followPlaylists()
        followSceneActivation()
        Task { await model.bootstrap() }
        #if DEBUG
        SiriDevHook.run()
        // `CTUNES_DEV_URL` opens a `ctunes://` URL a few seconds after
        // launch, the way a widget's link would: `simctl openurl` from the
        // terminal is another app's link and stops at the "Open in…?"
        // prompt.
        if let spec = ProcessInfo.processInfo.environment["CTUNES_DEV_URL"], let url = URL(string: spec) {
            let links = links, model = model, catalog = catalog
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                links.open(url, model: model, catalog: catalog)
            }
        }
        #endif
    }

    /// Siri learns the playlist names from the App Shortcuts' parameter
    /// query when they register, so the registration is refreshed when
    /// the names change: a playlist made this morning is speakable by
    /// the afternoon drive.
    private func followPlaylists() {
        let model = model
        Task { @MainActor in
            var titles = model.playlists.map(\.title)
            for await current in Observations({ model.playlists.map(\.title) }) where current != titles {
                titles = current
                CtunesShortcuts.updateAppShortcutParameters()
            }
        }
    }

    /// Coming to the front is when to look for the server again. On the
    /// notification rather than a window's `scenePhase`, so the car's
    /// scene counts: launched from CarPlay with the phone locked there is
    /// no window, and nothing on activation looked for the server again.
    /// Never removed: the runtime lives as long as the process.
    private func followSceneActivation() {
        let model = model
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                model.refreshFromCloud()
                switch model.state {
                case .offline: await model.reconnect()
                case .signedIn:
                    await model.checkConnection()
                    await model.resumeDownloads()
                default: break
                }
            }
        }
    }

    /// A queue that started offline reports timelines once the server is
    /// back, and one that started online keeps playing pinned files. And
    /// sign-out lives in the model, which doesn't know the player: stop
    /// playback and drop the cached audio when it happens.
    private func followModel() {
        let model = model, player = player, catalog = catalog
        Task { @MainActor in
            var generation = model.libraryGeneration
            var state = model.state
            var section = model.selectedSection?.key
            for await current in Observations({
                (state: model.state, generation: model.libraryGeneration, section: model.selectedSection?.key)
            }) {
                if current.generation != generation {
                    generation = current.generation
                    player.adopt(model.library)
                }
                // A library switch starts the catalog over with the root.
                if current.section != section {
                    section = current.section
                    catalog.reset()
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
