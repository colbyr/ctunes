import Foundation
import Network
import Observation
import PlexKit

/// Main-actor mirror of the offline store's pins and files, so views can
/// read download state without an await. The inventory is re-read from
/// disk on every cache event and after every pin or unpin; nothing here is
/// truth on its own.
///
/// Also the owner of the two per-device download settings: the quality a
/// pin is fetched at, and whether anything downloads on cellular. Both are
/// `UserDefaults`, never synced, since they are about this device's
/// network and disk.
@MainActor
@Observable
final class Downloads {
    /// How a pinned track is fetched: the file as stored, or MP3 under a
    /// cap from the server's download queue. Separate from the streaming
    /// quality, since downloads mostly happen at home. A change applies to
    /// what is fetched from here on: files already down keep their quality
    /// (an upgrade is Remove and Download again), and what a pin still
    /// wants is asked for again at the new one.
    var quality: StreamQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            guard quality != oldValue else { return }
            Task { await pinsChanged?() }
        }
    }
    private static let qualityKey = "downloadQuality"
    /// Whether the cache may fetch anything over cellular (or a hotspot:
    /// any path the system calls expensive). Off, the pump waits for
    /// Wi-Fi, pins and the play cache alike, so nothing is written to disk
    /// on cellular; what was in flight resumes when the path changes. On by
    /// default, which is what the app did before the switch existed.
    var allowsCellular: Bool {
        didSet {
            UserDefaults.standard.set(allowsCellular, forKey: Self.cellularKey)
            applyGate()
        }
    }
    private static let cellularKey = "cellularDownloads"
    /// Whether the current path is cellular or otherwise metered, from
    /// `NWPathMonitor`. Only ever a question of cost, never of reachability,
    /// which the server answering decides.
    private(set) var onExpensivePath = false
    /// Re-asks every pin for what it still wants, at the current quality.
    /// Set by the model, which owns the library.
    @ObservationIgnored var pinsChanged: (@MainActor () async -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    /// Every pin, file and album state for the server the library is on.
    private(set) var inventory = DownloadInventory()
    /// Albums with a file on disk but no pin of their own, offline: anything
    /// cached from a play, so the grid can tell playable from not. Empty
    /// online, where the inventory covers every file that matters.
    private(set) var available: Set<String> = []
    /// The same for playlists browsed: any with an item on disk.
    private(set) var availablePlaylists: Set<String> = []
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
        quality = UserDefaults.standard.string(forKey: Self.qualityKey)
            .flatMap(StreamQuality.init(rawValue:)) ?? .original
        allowsCellular = UserDefaults.standard.object(forKey: Self.cellularKey) == nil
            || UserDefaults.standard.bool(forKey: Self.cellularKey)
        events = Task { [weak self, cache] in
            for await _ in cache.events {
                guard let self else { return }
                self.refresh()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in self?.pathChanged(expensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "ctunes.downloads.path"))
        applyGate()
    }

    private func pathChanged(expensive: Bool) {
        guard expensive != onExpensivePath else { return }
        onExpensivePath = expensive
        applyGate()
    }

    /// Whether the pump may run right now.
    var downloadsAllowed: Bool { allowsCellular || !onExpensivePath }

    private func applyGate() {
        let cache = cache, allowsCellular = allowsCellular, allowed = downloadsAllowed
        Task {
            await cache.setAllowsCellular(allowsCellular)
            await cache.setDownloadsAllowed(allowed)
        }
        // The badges read "waiting" while the gate is closed.
        generation += 1
    }

    /// The cache sources for `library` at the download quality, for every
    /// store call that pins or reconciles. The token stays in a header.
    func sources(_ library: any LibrarySource) -> @Sendable (PlexTrack) -> TrackSource? {
        let quality = quality
        return { library.trackSource(for: $0, quality: quality) }
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
            && inventory.playlists.isEmpty && !inventory.favoritesPinned && inventory.files.isEmpty
    }

    var usage: Int { inventory.totalBytes }
    var favoritesPinned: Bool { inventory.favoritesPinned }

    // MARK: - State

    /// Offline, or with the gate closed on cellular, nothing is being
    /// fetched, so a pin still coming down reads as waiting rather than in
    /// flight; every state read goes through here.
    private func settled(_ state: DownloadState) -> DownloadState {
        offline || !downloadsAllowed ? state.waiting : state
    }

    func state(_ album: PlexAlbum) -> DownloadState {
        settled(inventory.state(of: album))
    }

    func state(artist key: String) -> DownloadState {
        settled(inventory.state(ofArtist: key, albums: albums))
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

    func state(_ playlist: PlexPlaylist) -> DownloadState {
        settled(inventory.state(ofPlaylist: playlist))
    }

    func isPinned(_ playlist: PlexPlaylist) -> Bool {
        inventory.isPlaylistPinned(playlist.ratingKey)
    }

    /// Something to play: a saved item down under any pin, or offline,
    /// one with a file left from an earlier play.
    func hasDownloads(_ playlist: PlexPlaylist) -> Bool {
        state(playlist).hasFiles || availablePlaylists.contains(playlist.ratingKey)
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

    /// Downloading, but nothing is being fetched: the last try failed and
    /// the cache is waiting out its backoff, or the server is away.
    func isWaiting(_ track: PlexTrack) -> Bool {
        guard let server, inventory.isDownloading(track, server: server) else { return false }
        return offline || !downloadsAllowed || inventory.isFailed(track, server: server)
    }

    /// The row glyph's state for one track, so a track reads like an album.
    func state(_ track: PlexTrack) -> DownloadState {
        if isDownloaded(track) { return .complete(undownloadable: 0) }
        if isDownloading(track) { return .downloading(done: 0, total: 1, stalled: isWaiting(track)) }
        return .none
    }

    func bytes(_ track: PlexTrack) -> Int? {
        guard let server else { return nil }
        return inventory.bytes(for: track, server: server)
    }

    /// The quality the file on disk was transcoded to; nil for an original
    /// or nothing down.
    func quality(_ track: PlexTrack) -> StreamQuality? {
        guard let server else { return nil }
        return inventory.quality(for: track, server: server)
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
                                 art: Self.art(library), sources: sources(library))
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
                                  art: Self.art(library), sources: sources(library))
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
                                  sources: sources(library))
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

    /// Drops a playlist pin; a track also under an album pin or the
    /// favorites keeps its file.
    func unpin(_ playlist: PlexPlaylist) {
        guard let server else { return }
        Task {
            await store.unpinPlaylist(playlist.ratingKey, server: server)
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
            availablePlaylists = []
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
            let availablePlaylists = offline ? await store.availablePlaylists(server: server) : []
            guard self.server == server else { return }
            self.inventory = inventory
            self.available = available
            self.availablePlaylists = availablePlaylists
            generation += 1
        }
    }
}
