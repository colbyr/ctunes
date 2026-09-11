import Foundation
import Observation
import PlexKit

/// Main-actor mirror of the offline store's pins and files, so views can
/// read download state without an await. The inventory is re-read from
/// disk on every cache event and after every pin or unpin; nothing here is
/// truth on its own.
@MainActor
@Observable
final class Downloads {
    /// Every pin, file and album state for the server the library is on.
    private(set) var inventory = DownloadInventory()
    /// Albums with a file on disk but no pin of their own, offline: anything
    /// cached from a play, so the grid can tell playable from not. Empty
    /// online, where the inventory covers every file that matters.
    private(set) var available: Set<String> = []
    /// The section's album list, for the totals an artist's badge needs:
    /// how many tracks each album has whether or not it was ever browsed.
    private(set) var albums: [PlexAlbum] = []
    /// Bumped on every refresh, so a per-track lookup that stats the disk
    /// still re-renders when a file lands.
    private(set) var generation = 0

    private let store: OfflineStore
    private let cache: TrackCache
    private(set) var server: String?
    private var offline = false
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    init(store: OfflineStore, cache: TrackCache) {
        self.store = store
        self.cache = cache
        events = Task { [weak self, cache] in
            for await _ in cache.events {
                guard let self else { return }
                self.refresh()
            }
        }
    }

    /// The server whose pins to show; nil clears everything.
    func attach(server: String?, offline: Bool) {
        self.server = server
        self.offline = offline
        if server == nil { albums = [] }
        refresh()
    }

    /// The section's albums as the browse root or the snapshot has them.
    func setAlbums(_ albums: [PlexAlbum]) {
        guard self.albums != albums else { return }
        self.albums = albums
    }

    var isEmpty: Bool {
        inventory.artists.isEmpty && inventory.albums.isEmpty && inventory.tracks.isEmpty
            && !inventory.favoritesPinned && inventory.files.isEmpty
    }

    var usage: Int { inventory.totalBytes }
    var favoritesPinned: Bool { inventory.favoritesPinned }

    // MARK: - State

    func state(_ album: PlexAlbum) -> DownloadState {
        inventory.state(of: album)
    }

    func state(artist key: String) -> DownloadState {
        inventory.state(ofArtist: key, albums: albums)
    }

    /// An album pin, or an artist pin covering it.
    func isPinned(_ album: PlexAlbum) -> Bool {
        inventory.isAlbumPinned(album.ratingKey)
    }

    func isPinned(artist key: String) -> Bool {
        inventory.isArtistPinned(key)
    }

    /// Wanted by an artist, album or track pin.
    func isPinned(_ track: PlexTrack) -> Bool {
        inventory.isTrackPinned(track)
    }

    /// Every fetchable track is on disk.
    func isDownloaded(_ album: PlexAlbum) -> Bool {
        state(album).isComplete
    }

    /// Something to play: a file down under any pin, or offline, any album
    /// with a file left from an earlier play.
    func hasDownloads(_ album: PlexAlbum) -> Bool {
        state(album).hasFiles || available.contains(album.ratingKey)
    }

    /// Whether the file is in the pinned root right now.
    func isDownloaded(_ track: PlexTrack) -> Bool {
        guard let server else { return false }
        return inventory.isDownloaded(track, server: server)
    }

    /// A pin wants the file and it isn't down yet.
    func isDownloading(_ track: PlexTrack) -> Bool {
        guard let server else { return false }
        return inventory.isDownloading(track, server: server)
    }

    func bytes(_ track: PlexTrack) -> Int? {
        guard let server else { return nil }
        return inventory.bytes(for: track, server: server)
    }

    /// Bytes on disk and files down for a list of tracks.
    func usage(of tracks: [PlexTrack]) -> (bytes: Int, files: Int) {
        guard let server else { return (0, 0) }
        return inventory.usage(of: tracks, server: server)
    }

    /// Whether the file is on disk in either root, so it can play offline.
    func isAvailable(_ track: PlexTrack) -> Bool {
        _ = generation
        guard let server, let part = track.part else { return false }
        return cache.localURL(server: server, part: part) != nil
    }

    /// The saved track list for an album, for the manager's pages.
    func tracks(inAlbum album: PlexAlbum) async -> [PlexTrack] {
        guard let server else { return [] }
        return await store.tracks(inAlbum: album.ratingKey, server: server) ?? []
    }

    // MARK: - Pins

    /// Pins the album: records it, saves its cover at 600px, and queues
    /// every track. Sources come from the library so the token stays in a
    /// header.
    func pin(_ album: PlexAlbum, tracks: [PlexTrack], section: String, library: any LibrarySource) {
        guard !library.isOffline else { return }
        Task {
            await store.pinAlbum(album, tracks: tracks, server: library.serverIdentifier, section: section,
                                 art: Self.art(library), sources: library.trackSource)
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

    /// Pins the artist: every album in `albums`, with `tracks` as the
    /// artist's whole list, filed under each.
    func pinArtist(key: String, title: String, thumb: String?, albums: [PlexAlbum], tracks: [PlexTrack],
                   section: String, library: any LibrarySource) {
        guard !library.isOffline else { return }
        Task {
            await store.pinArtist(key: key, title: title, thumb: thumb, albums: albums, tracks: tracks,
                                  server: library.serverIdentifier, section: section,
                                  art: Self.art(library), sources: library.trackSource)
            refresh()
        }
    }

    func unpinArtist(_ key: String) {
        guard let server else { return }
        Task {
            await store.unpinArtist(key, server: server)
            refresh()
        }
    }

    func pin(_ tracks: [PlexTrack], library: any LibrarySource) {
        guard !library.isOffline else { return }
        Task {
            await store.pinTracks(tracks, server: library.serverIdentifier, art: Self.art(library),
                                  sources: library.trackSource)
            refresh()
        }
    }

    /// Drops one track; an album or artist pin over it narrows to the rest.
    func unpin(_ track: PlexTrack) {
        guard let server else { return }
        Task {
            await store.unpinTrack(track, server: server)
            refresh()
        }
    }

    func removeAll() {
        Task {
            await store.clear()
            refresh()
        }
    }

    /// Drops the cache's failure backoff and re-enqueues every pinned track
    /// still missing, for a stalled download.
    func retry(resume: @escaping @MainActor () async -> Void) {
        Task {
            await cache.retryFailed()
            await resume()
            refresh()
        }
    }

    /// Covers and portraits at 600px, the size the album page and Now
    /// Playing show; the URL carries the token the way the image loader's
    /// own requests do, and only the bytes are written down.
    private static func art(_ library: any LibrarySource) -> OfflineStore.ArtResolver {
        { thumb in library.artworkURL(thumb, size: 600) }
    }

    // MARK: - Refresh

    /// Re-reads the inventory. Events arrive twice per file during an
    /// artist download, so a refresh that lands mid-refresh is folded into
    /// one more pass rather than queued.
    func refresh() {
        guard let server else {
            inventory = DownloadInventory()
            available = []
            generation += 1
            return
        }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let offline = offline
        Task {
            defer {
                refreshing = false
                if refreshAgain {
                    refreshAgain = false
                    refresh()
                }
            }
            let inventory = await store.inventory(server: server)
            let available = offline ? await store.availableAlbums(server: server) : []
            guard self.server == server else { return }
            self.inventory = inventory
            self.available = available
            generation += 1
        }
    }
}
