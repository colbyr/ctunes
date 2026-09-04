import Observation
import PlexKit

/// Main-actor mirror of the offline store's pin state, so views can read
/// download status without an await. Refreshed from disk on every cache
/// event and after every pin or unpin; nothing here is truth on its own.
@MainActor
@Observable
final class Downloads {
    /// By album ratingKey, for the server the library is on.
    private(set) var statuses: [String: OfflineStore.AlbumStatus] = [:]
    /// Offline only: albums with any file on disk, pinned or cached from a
    /// play, so the grid can tell playable from not.
    private(set) var available: Set<String> = []
    private(set) var favoritesPinned = false
    /// Bytes of pinned audio and art.
    private(set) var usage = 0
    /// Bumped on every refresh, so a per-track lookup that stats the disk
    /// still re-renders when a download lands.
    private(set) var generation = 0

    private let store: OfflineStore
    private let cache: TrackCache
    private var server: String?
    private var offline = false
    @ObservationIgnored private var events: Task<Void, Never>?

    init(store: OfflineStore, cache: TrackCache) {
        self.store = store
        self.cache = cache
        events = Task { [weak self, cache] in
            for await _ in cache.events {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    /// The server whose pins to show; nil clears everything.
    func attach(server: String?, offline: Bool) {
        self.server = server
        self.offline = offline
        refresh()
    }

    func status(_ album: PlexAlbum) -> OfflineStore.AlbumStatus? {
        statuses[album.ratingKey]
    }

    func isPinned(_ album: PlexAlbum) -> Bool {
        statuses[album.ratingKey] != nil
    }

    /// Every fetchable track is on disk.
    func isDownloaded(_ album: PlexAlbum) -> Bool {
        statuses[album.ratingKey]?.isDownloaded ?? false
    }

    /// Something to play: a pin with at least one file down, or offline,
    /// any album with a file left from an earlier play.
    func hasDownloads(_ album: PlexAlbum) -> Bool {
        statuses[album.ratingKey]?.hasDownloads ?? available.contains(album.ratingKey)
    }

    /// Whether the file is in the pinned root right now.
    func isPinned(_ track: PlexTrack) -> Bool {
        _ = generation
        guard let server, let part = track.part else { return false }
        return cache.isPinned(server: server, part: part)
    }

    /// Whether the file is on disk in either root, so it can play offline.
    func isAvailable(_ track: PlexTrack) -> Bool {
        _ = generation
        guard let server, let part = track.part else { return false }
        return cache.localURL(server: server, part: part) != nil
    }

    /// Pins the album: records it, saves its cover at 600px, and queues
    /// every track. Sources come from the library so the token stays in a
    /// header.
    func pin(_ album: PlexAlbum, tracks: [PlexTrack], section: String, library: any LibrarySource) {
        guard !library.isOffline else { return }
        let server = library.serverIdentifier
        let art = library.artworkURL(album.thumb ?? tracks.first?.thumb, size: 600)
        Task {
            await store.pinAlbum(album, tracks: tracks, server: server, section: section, art: art,
                                 sources: library.trackSource)
            refresh()
        }
    }

    func unpin(_ album: PlexAlbum) {
        guard let server else { return }
        Task {
            await store.unpinAlbum(album.ratingKey, server: server)
            refresh()
        }
    }

    func removeAll() {
        Task {
            await store.clear()
            refresh()
        }
    }

    func refresh() {
        guard let server else {
            statuses = [:]
            available = []
            favoritesPinned = false
            usage = 0
            generation += 1
            return
        }
        let offline = offline
        Task {
            let statuses = await store.statuses(server: server)
            let pinned = await store.favoritesPinned(server: server)
            let usage = await store.usage()
            let available = offline ? await store.availableAlbums(server: server) : []
            self.statuses = statuses
            favoritesPinned = pinned
            self.usage = usage
            self.available = available
            generation += 1
        }
    }
}
