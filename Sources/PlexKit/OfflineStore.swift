import Foundation

/// Owns what the track cache deliberately doesn't: which albums are pinned,
/// whether the favorites set is, the per-album track lists needed to play
/// them with no server, the library snapshot the browse root reads offline,
/// and the album covers. It never downloads audio itself; it hands
/// `TrackSource`s to the cache and reads the file system for status.
///
/// Layout under `directory`:
///
///     Tracks/<server>/<partId>-<stamp>.<ext>   the cache's pinned root
///     <server>/manifest.json                   Manifest
///     <server>/albums/<ratingKey>.json         [PlexTrack] per album ever browsed
///     <server>/favorites.json                  [PlexTrack] in the favorites group
///     <server>/<section>/library.json          LibrarySnapshot
///     <server>/art/<name>.jpg                  album covers for pinned albums
///
/// Reference counting is derived, not stored: a file is wanted while any
/// pinned album or the favorites group lists a track with that cache path.
public actor OfflineStore {
    public nonisolated let directory: URL
    private let cache: TrackCache
    private let session: URLSession

    private var manifests: [String: Manifest] = [:]
    private var albumTracks: [String: [PlexTrack]] = [:]
    private var favorites: [String: [PlexTrack]] = [:]

    public init(directory: URL, cache: TrackCache, session: URLSession = .shared) {
        self.directory = directory
        self.cache = cache
        self.session = session
    }

    struct Manifest: Codable, Equatable {
        struct PinnedAlbum: Codable, Equatable {
            var title: String
            var section: String
            var pinnedAt: Date
        }
        /// By album ratingKey.
        var albums: [String: PinnedAlbum] = [:]
        var favoritesPinned = false
    }

    public enum AlbumStatus: Sendable, Equatable {
        case pending(done: Int, total: Int)
        case complete
        /// Every fetchable track is down; `undownloadable` have no `cacheKey`.
        case partial(undownloadable: Int)

        public var isDownloaded: Bool {
            switch self {
            case .complete, .partial: true
            case .pending: false
            }
        }

        /// At least one file is on disk, so there is something to play.
        public var hasDownloads: Bool {
            switch self {
            case .complete, .partial: true
            case .pending(let done, _): done > 0
            }
        }
    }

    // MARK: - Pins

    /// Records the pin, saves the track list and the cover, and hands the
    /// cache every fetchable track in album order. `sources` resolves the
    /// request for each track, so the token rides in a header and is never
    /// written down.
    public func pinAlbum(
        _ album: PlexAlbum,
        tracks: [PlexTrack],
        server: String,
        section: String,
        art: URL?,
        sources: @Sendable (PlexTrack) -> TrackSource?
    ) async {
        var manifest = manifest(server)
        manifest.albums[album.ratingKey] = .init(title: album.title, section: section, pinnedAt: Date())
        try? write(tracks, to: albumsDirectory(server).appending(path: "\(album.ratingKey).json"))
        albumTracks[albumKey(server, album.ratingKey)] = tracks
        save(manifest, server: server)
        await cache.pin(tracks.compactMap(sources))
        // A track's thumb is its album's, which covers an album record with
        // no thumb of its own.
        if let art, let thumb = album.thumb ?? tracks.first?.thumb, artURL(thumb, server: server) == nil {
            await saveArt(from: art, thumb: thumb, server: server)
        }
    }

    /// Drops the album and unpins every file nothing else still wants.
    public func unpinAlbum(_ ratingKey: String, server: String) async {
        var manifest = manifest(server)
        guard manifest.albums.removeValue(forKey: ratingKey) != nil else { return }
        let before = wantedPaths(server)
        // The track list stays: it's what lets the album page show which
        // tracks are still in the cache root offline.
        save(manifest, server: server)
        let after = wantedPaths(server)
        await cache.unpin(Array(before.subtracting(after)))
    }

    public func setFavoritesPinned(_ enabled: Bool, server: String) async {
        var manifest = manifest(server)
        guard manifest.favoritesPinned != enabled else { return }
        let before = wantedPaths(server)
        manifest.favoritesPinned = enabled
        save(manifest, server: server)
        if !enabled {
            let after = wantedPaths(server)
            await cache.unpin(Array(before.subtracting(after)))
        }
    }

    /// Replaces the favorites group with `tracks`: new keys enqueue, dropped
    /// keys unpin unless a pinned album still references the file. Does
    /// nothing unless the favorites pin is on.
    public func setFavorites(
        _ tracks: [PlexTrack],
        server: String,
        sources: @Sendable (PlexTrack) -> TrackSource?
    ) async {
        guard manifest(server).favoritesPinned else { return }
        let before = wantedPaths(server)
        favorites[server] = tracks
        try? write(tracks, to: serverDirectory(server).appending(path: "favorites.json"))
        let after = wantedPaths(server)
        await cache.unpin(Array(before.subtracting(after)))
        await cache.pin(tracks.compactMap(sources))
    }

    /// Re-enqueues every pinned track with no file yet. Called on connect and
    /// on foreground, since nothing survives the app being suspended.
    public func resume(server: String, sources: @Sendable (PlexTrack) -> TrackSource?) async {
        await cache.pin(pinnedTracks(server: server).compactMap(sources))
    }

    /// Every pinned album's status, by ratingKey, read from disk now.
    public func statuses(server: String) -> [String: AlbumStatus] {
        var result: [String: AlbumStatus] = [:]
        for ratingKey in manifest(server).albums.keys {
            let tracks = savedTracks(server, ratingKey)
            var done = 0, total = 0, undownloadable = 0
            for track in tracks {
                guard let part = track.part, part.cacheKey != nil else {
                    undownloadable += 1
                    continue
                }
                total += 1
                if cache.localURL(server: server, part: part) != nil { done += 1 }
            }
            result[ratingKey] = done < total
                ? .pending(done: done, total: total)
                : undownloadable > 0 ? .partial(undownloadable: undownloadable) : .complete
        }
        return result
    }

    public func pinnedAlbumKeys(server: String) -> Set<String> {
        Set(manifest(server).albums.keys)
    }

    public func favoritesPinned(server: String) -> Bool {
        manifest(server).favoritesPinned
    }

    /// Bytes of pinned audio and art.
    public func usage() async -> Int {
        var total = await cache.pinnedUsage()
        let manager = FileManager.default
        guard let servers = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return total
        }
        for server in servers where server.lastPathComponent != cache.pinnedDirectory.lastPathComponent {
            let art = server.appending(path: "art")
            guard let files = try? manager.contentsOfDirectory(at: art, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for file in files {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    // MARK: - Offline reads

    /// Remembers an album's tracks as browsed online, so offline the page
    /// can list them and play whichever are on disk, pinned or merely
    /// cached from a play.
    public func saveTracks(_ tracks: [PlexTrack], inAlbum ratingKey: String, server: String) {
        guard !tracks.isEmpty, savedTracks(server, ratingKey) != tracks else { return }
        albumTracks[albumKey(server, ratingKey)] = tracks
        try? write(tracks, to: albumsDirectory(server).appending(path: "\(ratingKey).json"))
    }

    /// The saved track list for any album browsed or pinned; nil when the
    /// album was never seen.
    public func tracks(inAlbum ratingKey: String, server: String) -> [PlexTrack]? {
        let tracks = savedTracks(server, ratingKey)
        return tracks.isEmpty ? nil : tracks
    }

    /// Every album with a saved track list and at least one file on disk in
    /// either root. Only worth computing offline: it stats every saved
    /// track.
    public func availableAlbums(server: String) -> Set<String> {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: albumsDirectory(server).path) else { return [] }
        var result: Set<String> = []
        for file in files where file.hasSuffix(".json") {
            let ratingKey = String(file.dropLast(5))
            let onDisk = savedTracks(server, ratingKey).contains { track in
                track.part.map { cache.localURL(server: server, part: $0) != nil } ?? false
            }
            if onDisk { result.insert(ratingKey) }
        }
        return result
    }

    /// The favorites group, whether or not the pin is on.
    public func favoriteTracks(server: String) -> [PlexTrack] {
        if let loaded = favorites[server] { return loaded }
        let loaded: [PlexTrack] = read(serverDirectory(server).appending(path: "favorites.json")) ?? []
        favorites[server] = loaded
        return loaded
    }

    /// Every track any pin wants, albums first in pin order, then favorites.
    public func pinnedTracks(server: String) -> [PlexTrack] {
        let manifest = manifest(server)
        var result: [PlexTrack] = []
        for (ratingKey, _) in manifest.albums.sorted(by: { $0.value.pinnedAt < $1.value.pinnedAt }) {
            result += savedTracks(server, ratingKey)
        }
        if manifest.favoritesPinned { result += favoriteTracks(server: server) }
        return result
    }

    // MARK: - Snapshot

    public func save(_ snapshot: LibrarySnapshot) throws {
        try write(snapshot, to: sectionDirectory(snapshot.server, snapshot.section.key).appending(path: "library.json"))
    }

    /// The saved snapshot for the section, or any section of the server
    /// when none is named.
    public func snapshot(server: String, section: String?) -> LibrarySnapshot? {
        if let section {
            return read(sectionDirectory(server, section).appending(path: "library.json"))
        }
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: serverDirectory(server), includingPropertiesForKeys: nil) else {
            return nil
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let snapshot: LibrarySnapshot = read(child.appending(path: "library.json")) { return snapshot }
        }
        return nil
    }

    // MARK: - Art

    /// The saved cover for a thumb path, if there is one. Path math plus a
    /// stat, so `OfflineLibrary.artworkURL` stays synchronous.
    public nonisolated func artURL(_ thumb: String?, server: String) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        let url = artDirectory(server).appending(path: Self.artName(thumb))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `/library/metadata/649/thumb/1746246600` → `library-metadata-649-thumb-1746246600.jpg`.
    /// The stamp is in the path, so a replaced cover gets a new file.
    static func artName(_ thumb: String) -> String {
        let safe = thumb.drop { $0 == "/" }.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return safe + ".jpg"
    }

    private func saveArt(from url: URL, thumb: String, server: String) async {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              !data.isEmpty
        else { return }
        let destination = artDirectory(server).appending(path: Self.artName(thumb))
        try? FileManager.default.createDirectory(at: artDirectory(server), withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
    }

    // MARK: - Clear

    /// Forgets every pin and snapshot and empties the pinned root.
    public func clear() async {
        manifests = [:]
        albumTracks = [:]
        favorites = [:]
        await cache.clearPinned()
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children where child.standardizedFileURL != cache.pinnedDirectory.standardizedFileURL {
            try? manager.removeItem(at: child)
        }
    }

    // MARK: - Internals

    /// Cache paths any pin wants right now.
    private func wantedPaths(_ server: String) -> Set<String> {
        Set(pinnedTracks(server: server).compactMap { $0.part?.cachePath(server: server) })
    }

    private func albumKey(_ server: String, _ ratingKey: String) -> String { "\(server)/\(ratingKey)" }

    private func savedTracks(_ server: String, _ ratingKey: String) -> [PlexTrack] {
        let key = albumKey(server, ratingKey)
        if let loaded = albumTracks[key] { return loaded }
        let loaded: [PlexTrack] = read(albumsDirectory(server).appending(path: "\(ratingKey).json")) ?? []
        albumTracks[key] = loaded
        return loaded
    }

    private func manifest(_ server: String) -> Manifest {
        if let loaded = manifests[server] { return loaded }
        let loaded: Manifest = read(serverDirectory(server).appending(path: "manifest.json")) ?? Manifest()
        manifests[server] = loaded
        return loaded
    }

    private func save(_ manifest: Manifest, server: String) {
        manifests[server] = manifest
        try? write(manifest, to: serverDirectory(server).appending(path: "manifest.json"))
    }

    private nonisolated func serverDirectory(_ server: String) -> URL {
        directory.appending(path: server)
    }

    private nonisolated func sectionDirectory(_ server: String, _ section: String) -> URL {
        serverDirectory(server).appending(path: section)
    }

    private nonisolated func albumsDirectory(_ server: String) -> URL {
        serverDirectory(server).appending(path: "albums")
    }

    private nonisolated func artDirectory(_ server: String) -> URL {
        serverDirectory(server).appending(path: "art")
    }

    private func read<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
