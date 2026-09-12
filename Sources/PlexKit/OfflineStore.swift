import Foundation

/// Owns what the track cache deliberately doesn't: which artists, albums
/// and tracks are pinned, whether the favorites set is, the per-album track
/// lists needed to play them with no server, the library snapshot the
/// browse root reads offline, and the covers. It never downloads audio
/// itself; it hands `TrackSource`s to the cache and reads the file system
/// for status.
///
/// Layout under `directory`:
///
///     Tracks/<server>/<partId>-<stamp>.<ext>   the cache's pinned root
///     <server>/manifest.json                   Manifest
///     <server>/artists/<ratingKey>.json        [PlexAlbum] per pinned artist
///     <server>/albums/<ratingKey>.json         [PlexTrack] per album ever browsed
///     <server>/tracks.json                     [PlexTrack] pinned on their own
///     <server>/favorites.json                  [PlexTrack] in the favorites group
///     <server>/<section>/library.json          LibrarySnapshot
///     <server>/art/<name>.jpg                  covers and portraits for pinned items
///
/// The pins form a tree, artist over album over track, and the three kinds
/// are kept disjoint: pinning an artist absorbs their album and track pins,
/// and removing an album or a track under a wider pin narrows that pin to
/// what's left rather than dropping it. Reference counting is derived, not
/// stored: a file is wanted while any pin or the favorites group lists a
/// track with that cache path.
public actor OfflineStore {
    public nonisolated let directory: URL
    private let cache: TrackCache
    private let session: URLSession

    private var manifests: [String: Manifest] = [:]
    private var albumTracks: [String: [PlexTrack]] = [:]
    private var artistAlbums: [String: [PlexAlbum]] = [:]
    private var trackPins: [String: [PlexTrack]] = [:]
    private var favorites: [String: [PlexTrack]] = [:]

    public init(directory: URL, cache: TrackCache, session: URLSession = .shared) {
        self.directory = directory
        self.cache = cache
        self.session = session
    }

    struct Manifest: Codable, Equatable {
        struct PinnedArtist: Codable, Equatable {
            var title: String
            var thumb: String?
            var section: String
            var pinnedAt: Date
        }
        struct PinnedAlbum: Codable, Equatable {
            var title: String
            var section: String
            var pinnedAt: Date
            /// The record as pinned. Absent from manifests written before
            /// artist pins existed, when the saved tracks stand in.
            var album: PlexAlbum?
        }
        /// By artist ratingKey.
        var artists: [String: PinnedArtist] = [:]
        /// By album ratingKey.
        var albums: [String: PinnedAlbum] = [:]
        var favoritesPinned = false

        init() {}

        /// `artists` is new; a manifest from before it decodes without one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            artists = try c.decodeIfPresent([String: PinnedArtist].self, forKey: .artists) ?? [:]
            albums = try c.decodeIfPresent([String: PinnedAlbum].self, forKey: .albums) ?? [:]
            favoritesPinned = try c.decodeIfPresent(Bool.self, forKey: .favoritesPinned) ?? false
        }
    }

    /// What `art` resolves: the server's URL for a thumb path, carrying the
    /// token in the query the way the image loader fetches it, or nil to
    /// save nothing.
    public typealias ArtResolver = @Sendable (String) -> URL?

    // MARK: - Pins

    /// Pins every album the artist had when asked, in the order given.
    /// `tracks` is the artist's whole list in one fetch; it is filed under
    /// each album so the pages work offline. Album and track pins under the
    /// artist fold into this one.
    public func pinArtist(
        key: String,
        title: String,
        thumb: String?,
        albums: [PlexAlbum],
        tracks: [PlexTrack],
        server: String,
        section: String,
        art: ArtResolver,
        sources: @Sendable (PlexTrack) -> TrackSource?
    ) async {
        var manifest = manifest(server)
        let pinnedAt = manifest.artists[key]?.pinnedAt ?? Date()
        manifest.artists[key] = .init(title: title, thumb: thumb, section: section, pinnedAt: pinnedAt)
        for album in albums { manifest.albums.removeValue(forKey: album.ratingKey) }
        let albumKeys = Set(albums.map(\.ratingKey))
        setTrackPins(trackPins(server: server).filter { !albumKeys.contains($0.parentRatingKey ?? "") }, server: server)
        try? write(albums, to: artistsDirectory(server).appending(path: "\(key).json"))
        artistAlbums[albumKey(server, key)] = albums

        let grouped = Dictionary(grouping: tracks) { $0.parentRatingKey ?? "" }
        var ordered: [PlexTrack] = []
        for album in albums {
            let list = (grouped[album.ratingKey] ?? []).sorted {
                ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0)
            }
            saveTracks(list, inAlbum: album.ratingKey, server: server)
            ordered += list.isEmpty ? savedTracks(server, album.ratingKey) : list
        }
        save(manifest, server: server)
        await cache.pin(ordered.compactMap(sources))
        await saveArt(thumb, resolve: art, server: server)
        for album in albums {
            await saveArt(album.thumb ?? grouped[album.ratingKey]?.first?.thumb, resolve: art, server: server)
        }
    }

    /// Drops everything pinned under the artist: the artist pin, and any
    /// album or track pins of theirs, so an artist whose albums were pinned
    /// one by one clears the same way. Unpins every file nothing else still
    /// wants. The album lists stay, for the pages offline.
    public func unpinArtist(_ key: String, server: String) async {
        var manifest = manifest(server)
        let before = wantedPaths(server)
        manifest.artists.removeValue(forKey: key)
        for (albumKey, pin) in manifest.albums where artistKey(of: albumKey, pin, server: server) == key {
            manifest.albums.removeValue(forKey: albumKey)
        }
        setTrackPins(trackPins(server: server).filter { $0.grandparentRatingKey != key }, server: server)
        save(manifest, server: server)
        try? FileManager.default.removeItem(at: artistsDirectory(server).appending(path: "\(key).json"))
        artistAlbums[self.albumKey(server, key)] = []
        await cache.unpin(Array(before.subtracting(wantedPaths(server))))
    }

    /// The artist of an album pin, from its record or its saved tracks.
    private func artistKey(of ratingKey: String, _ pin: Manifest.PinnedAlbum, server: String) -> String? {
        pin.album?.parentRatingKey ?? savedTracks(server, ratingKey).first?.grandparentRatingKey
    }

    /// Records the pin, saves the track list and the cover, and hands the
    /// cache every fetchable track in album order. `sources` resolves the
    /// request for each track, so the token rides in a header and is never
    /// written down. Track pins under the album fold into it.
    public func pinAlbum(
        _ album: PlexAlbum,
        tracks: [PlexTrack],
        server: String,
        section: String,
        art: ArtResolver,
        sources: @Sendable (PlexTrack) -> TrackSource?
    ) async {
        var manifest = manifest(server)
        let pinnedAt = manifest.albums[album.ratingKey]?.pinnedAt ?? Date()
        manifest.albums[album.ratingKey] = .init(title: album.title, section: section, pinnedAt: pinnedAt, album: album)
        setTrackPins(trackPins(server: server).filter { $0.parentRatingKey != album.ratingKey }, server: server)
        saveTracks(tracks, inAlbum: album.ratingKey, server: server)
        save(manifest, server: server)
        await cache.pin(tracks.compactMap(sources))
        // A track's thumb is its album's, which covers an album record with
        // no thumb of its own.
        await saveArt(album.thumb ?? tracks.first?.thumb, resolve: art, server: server)
    }

    /// Drops the album and unpins every file nothing else still wants. An
    /// artist pin covering it narrows to their other albums, and track
    /// pins on it go with it.
    public func unpinAlbum(_ ratingKey: String, server: String) async {
        var manifest = manifest(server)
        let before = wantedPaths(server)
        narrowArtistPin(covering: ratingKey, in: &manifest, server: server)
        manifest.albums.removeValue(forKey: ratingKey)
        setTrackPins(trackPins(server: server).filter { $0.parentRatingKey != ratingKey }, server: server)
        // The track list stays: it's what lets the album page show which
        // tracks are still in the cache root offline.
        save(manifest, server: server)
        await cache.unpin(Array(before.subtracting(wantedPaths(server))))
    }

    /// Pins tracks on their own. One already under an album or artist pin
    /// is skipped; the pin it has covers it.
    public func pinTracks(
        _ tracks: [PlexTrack],
        server: String,
        art: ArtResolver,
        sources: @Sendable (PlexTrack) -> TrackSource?
    ) async {
        let manifest = manifest(server)
        let covered = pinnedAlbumKeys(manifest, server: server)
        var pins = trackPins(server: server)
        var added: [PlexTrack] = []
        for track in tracks where !covered.contains(track.parentRatingKey ?? "") {
            guard !pins.contains(where: { $0.ratingKey == track.ratingKey }) else { continue }
            pins.append(track)
            added.append(track)
        }
        guard !added.isEmpty else { return }
        setTrackPins(pins, server: server)
        await cache.pin(added.compactMap(sources))
        for thumb in Set(added.compactMap(\.thumb)) {
            await saveArt(thumb, resolve: art, server: server)
        }
    }

    /// Drops one track. An album pin on it narrows to track pins on the
    /// album's other tracks, and an artist pin above that narrows to the
    /// artist's other albums first. A favorite kept offline keeps its file.
    public func unpinTrack(_ track: PlexTrack, server: String) async {
        var manifest = manifest(server)
        let before = wantedPaths(server)
        var pins = trackPins(server: server).filter { $0.ratingKey != track.ratingKey }
        if let album = track.parentRatingKey, pinnedAlbumKeys(manifest, server: server).contains(album) {
            narrowArtistPin(covering: album, in: &manifest, server: server)
            manifest.albums.removeValue(forKey: album)
            for sibling in savedTracks(server, album) where sibling.ratingKey != track.ratingKey {
                guard !pins.contains(where: { $0.ratingKey == sibling.ratingKey }) else { continue }
                pins.append(sibling)
            }
        }
        setTrackPins(pins, server: server)
        save(manifest, server: server)
        await cache.unpin(Array(before.subtracting(wantedPaths(server))))
    }

    /// Replaces an artist pin that covers the album with album pins on
    /// their other albums, dated a millisecond apart from the artist's own
    /// date so the manager keeps them together, in the artist's order.
    private func narrowArtistPin(covering album: String, in manifest: inout Manifest, server: String) {
        for (key, artist) in manifest.artists {
            let albums = savedArtistAlbums(server, key)
            guard albums.contains(where: { $0.ratingKey == album }) else { continue }
            manifest.artists.removeValue(forKey: key)
            for (offset, other) in albums.enumerated() where other.ratingKey != album {
                manifest.albums[other.ratingKey] = .init(
                    title: other.title, section: artist.section,
                    pinnedAt: artist.pinnedAt.addingTimeInterval(Double(offset) / 1000), album: other
                )
            }
            try? FileManager.default.removeItem(at: artistsDirectory(server).appending(path: "\(key).json"))
            artistAlbums[albumKey(server, key)] = []
        }
    }

    public func setFavoritesPinned(_ enabled: Bool, server: String) async {
        var manifest = manifest(server)
        guard manifest.favoritesPinned != enabled else { return }
        let before = wantedPaths(server)
        manifest.favoritesPinned = enabled
        save(manifest, server: server)
        if !enabled {
            await cache.unpin(Array(before.subtracting(wantedPaths(server))))
        }
    }

    /// Replaces the favorites group with `tracks`: new keys enqueue, dropped
    /// keys unpin unless another pin still references the file. Does
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
        await cache.unpin(Array(before.subtracting(wantedPaths(server))))
        await cache.pin(tracks.compactMap(sources))
    }

    /// Re-enqueues every pinned track with no file yet. Called on connect and
    /// on foreground, since nothing survives the app being suspended.
    public func resume(server: String, sources: @Sendable (PlexTrack) -> TrackSource?) async {
        await cache.pin(pinnedTracks(server: server).compactMap(sources))
    }

    /// Every pin, every file and every album's state, read from disk now.
    public func inventory(server: String) async -> DownloadInventory {
        let manifest = manifest(server)
        var inventory = DownloadInventory()
        inventory.files = await cache.pinnedFiles()
        inventory.failed = await cache.failedPaths()
        inventory.artists = manifest.artists
            .sorted { $0.value.pinnedAt < $1.value.pinnedAt }
            .map { key, artist in
                .init(key: key, title: artist.title, thumb: artist.thumb,
                      albums: savedArtistAlbums(server, key), pinnedAt: artist.pinnedAt)
            }
        inventory.albums = manifest.albums
            .sorted { $0.value.pinnedAt < $1.value.pinnedAt }
            .map { key, pin in
                .init(album: pin.album.map { withArt($0, server: server) } ?? syntheticAlbum(key, pin, server: server),
                      pinnedAt: pin.pinnedAt)
            }
        inventory.tracks = trackPins(server: server)
        inventory.favoritesPinned = manifest.favoritesPinned
        inventory.favorites = favoriteTracks(server: server)
        inventory.artBytes = artBytes(server)

        let wanted = pinnedTracks(server: server)
        inventory.wanted = Set(wanted.compactMap { $0.part?.cachePath(server: server) })
        let wantedKeys = Set(wanted.map(\.ratingKey))
        let pinnedAlbums = pinnedAlbumKeys(manifest, server: server)
        let loose = inventory.tracks + inventory.favorites

        var albumKeys = savedAlbumKeys(server)
        albumKeys.formUnion(loose.compactMap(\.parentRatingKey))
        for key in albumKeys {
            var tracks = savedTracks(server, key)
            var status = AlbumDownloadStatus(known: tracks.count, pinned: pinnedAlbums.contains(key))
            if tracks.isEmpty {
                var seen: Set<String> = []
                tracks = loose.filter { $0.parentRatingKey == key && seen.insert($0.ratingKey).inserted }
            }
            status.artistKey = tracks.first?.grandparentRatingKey
            for track in tracks {
                let isWanted = wantedKeys.contains(track.ratingKey)
                guard let path = track.part?.cachePath(server: server) else {
                    if isWanted { status.undownloadable += 1 }
                    continue
                }
                if let size = inventory.files[path] {
                    status.done += 1
                    status.bytes += size
                } else if isWanted {
                    status.missing += 1
                    if inventory.failed.contains(path) { status.failed += 1 }
                }
            }
            // A browsed album with nothing down still counts toward its
            // artist's total; one known only through a heart that's gone
            // does not.
            if status.done > 0 || status.missing > 0 || status.pinned || status.known > 0 {
                inventory.statuses[key] = status
            }
        }
        return inventory
    }

    /// Pinned on its own or through an artist.
    public func pinnedAlbumKeys(server: String) -> Set<String> {
        pinnedAlbumKeys(manifest(server), server: server)
    }

    private func pinnedAlbumKeys(_ manifest: Manifest, server: String) -> Set<String> {
        var keys = Set(manifest.albums.keys)
        for key in manifest.artists.keys {
            keys.formUnion(savedArtistAlbums(server, key).map(\.ratingKey))
        }
        return keys
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
            total += artBytes(server.lastPathComponent)
        }
        return total
    }

    private func artBytes(_ server: String) -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: artDirectory(server), includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
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

    /// The saved track list for any album browsed or pinned, or failing
    /// that the pinned tracks and favorites on the album, so an album
    /// reached only through those still has a page offline; nil when the
    /// album was never seen.
    public func tracks(inAlbum ratingKey: String, server: String) -> [PlexTrack]? {
        let tracks = savedTracks(server, ratingKey)
        if !tracks.isEmpty { return tracks }
        var seen: Set<String> = []
        let loose = (trackPins(server: server) + favoriteTracks(server: server))
            .filter { $0.parentRatingKey == ratingKey && seen.insert($0.ratingKey).inserted }
        return loose.isEmpty ? nil : loose
    }

    /// Every album with a saved track list and at least one file on disk in
    /// either root, plus the albums of pinned tracks and favorites on disk.
    /// Only worth computing offline: it stats every saved track.
    public func availableAlbums(server: String) -> Set<String> {
        var result: Set<String> = []
        for track in trackPins(server: server) + favoriteTracks(server: server) where onDisk(track, server: server) {
            if let album = track.parentRatingKey { result.insert(album) }
        }
        for ratingKey in savedAlbumKeys(server) {
            if savedTracks(server, ratingKey).contains(where: { onDisk($0, server: server) }) {
                result.insert(ratingKey)
            }
        }
        return result
    }

    private func onDisk(_ track: PlexTrack, server: String) -> Bool {
        track.part.map { cache.localURL(server: server, part: $0) != nil } ?? false
    }

    /// The favorites group, whether or not the pin is on.
    public func favoriteTracks(server: String) -> [PlexTrack] {
        if let loaded = favorites[server] { return loaded }
        let loaded: [PlexTrack] = read(serverDirectory(server).appending(path: "favorites.json")) ?? []
        favorites[server] = loaded
        return loaded
    }

    /// Tracks pinned on their own, in pin order.
    public func trackPins(server: String) -> [PlexTrack] {
        if let loaded = trackPins[server] { return loaded }
        let loaded: [PlexTrack] = read(serverDirectory(server).appending(path: "tracks.json")) ?? []
        trackPins[server] = loaded
        return loaded
    }

    private func setTrackPins(_ tracks: [PlexTrack], server: String) {
        guard trackPins(server: server) != tracks else { return }
        trackPins[server] = tracks
        try? write(tracks, to: serverDirectory(server).appending(path: "tracks.json"))
    }

    /// Every track any pin wants: artists in pin order, their albums in
    /// list order, then album pins, track pins and the favorites.
    public func pinnedTracks(server: String) -> [PlexTrack] {
        let manifest = manifest(server)
        var result: [PlexTrack] = []
        for (key, _) in manifest.artists.sorted(by: { $0.value.pinnedAt < $1.value.pinnedAt }) {
            for album in savedArtistAlbums(server, key) {
                result += savedTracks(server, album.ratingKey)
            }
        }
        for (ratingKey, _) in manifest.albums.sorted(by: { $0.value.pinnedAt < $1.value.pinnedAt }) {
            result += savedTracks(server, ratingKey)
        }
        result += trackPins(server: server)
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

    /// Saves the image for a thumb path unless it's already down. One small
    /// request through the store's own session, not the pump: nothing
    /// worth serialising behind the audio.
    private func saveArt(_ thumb: String?, resolve: ArtResolver, server: String) async {
        guard let thumb, !thumb.isEmpty, artURL(thumb, server: server) == nil, let url = resolve(thumb) else { return }
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
        artistAlbums = [:]
        trackPins = [:]
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

    private func savedArtistAlbums(_ server: String, _ ratingKey: String) -> [PlexAlbum] {
        let key = albumKey(server, ratingKey)
        if let loaded = artistAlbums[key] { return loaded }
        let loaded: [PlexAlbum] = read(artistsDirectory(server).appending(path: "\(ratingKey).json")) ?? []
        artistAlbums[key] = loaded
        return loaded
    }

    /// Every album with a saved track list.
    private func savedAlbumKeys(_ server: String) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: albumsDirectory(server).path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// The record with its tracks' cover when it has none of its own: an
    /// album reached by rating key alone knows its title, not its art.
    private func withArt(_ album: PlexAlbum, server: String) -> PlexAlbum {
        guard album.thumb == nil, let thumb = savedTracks(server, album.ratingKey).first?.thumb else { return album }
        return PlexAlbum(
            ratingKey: album.ratingKey, title: album.title, parentRatingKey: album.parentRatingKey,
            parentTitle: album.parentTitle, year: album.year, thumb: thumb, addedAt: album.addedAt,
            lastViewedAt: album.lastViewedAt, viewCount: album.viewCount,
            leafCount: album.leafCount ?? savedTracks(server, album.ratingKey).count,
            originallyAvailableAt: album.originallyAvailableAt, genres: album.genres
        )
    }

    /// An album record for a pin written before the manifest kept one,
    /// from what its tracks know.
    private func syntheticAlbum(_ key: String, _ pin: Manifest.PinnedAlbum, server: String) -> PlexAlbum {
        let tracks = savedTracks(server, key)
        return PlexAlbum(
            ratingKey: key,
            title: pin.title,
            parentRatingKey: tracks.first?.grandparentRatingKey,
            parentTitle: tracks.first?.grandparentTitle,
            year: nil,
            thumb: tracks.first?.thumb,
            leafCount: tracks.isEmpty ? nil : tracks.count
        )
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

    private nonisolated func artistsDirectory(_ server: String) -> URL {
        serverDirectory(server).appending(path: "artists")
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
