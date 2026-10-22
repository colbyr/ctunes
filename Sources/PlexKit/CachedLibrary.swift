import Foundation
import os
import Synchronization

/// The one library the app holds for a server and section: the saved
/// copy of every request, and a connection to the server that discovery
/// attaches and detaches. Every read hands back what is saved and asks
/// the server behind it when one is attached and the copy is older than
/// `revalidateAfter`; a miss with a connection waits for the fetch, a
/// miss without one is `PlexError.offline`. A revalidation that fails
/// changes nothing on screen and is reported once through
/// `connectionFailed`, so the screens never see a transport error for
/// anything they have seen before. Writes go to the connection or throw.
///
/// There is no offline library and no swap: entering and leaving offline
/// is the connection going nil and back, under the same object, the same
/// stack and the same queue. `changes` yields the key of every saved
/// copy that lands, which the app mirrors as a revision the screens key
/// their tasks on; a read inside the floor is disk only, which is what
/// makes a task run again cheaply.
public actor CachedLibrary: LibrarySource {
    public nonisolated let id: LibraryID
    private let store: OfflineStore
    /// The account's or the server's token, for artwork URLs with no
    /// connection; never written.
    private let token: String?
    /// The connection, read without a hop: the player picks an item URL
    /// synchronously, and a hop would let the cursor move under it.
    private nonisolated let connectionBox = Mutex<PlexLibrary?>(nil)
    /// What `server.json` knew, for artwork and sections with no connection.
    private nonisolated let recordBox: Mutex<ServerRecord?>

    /// How old a saved copy may be before a read asks the server again.
    /// Inside it a read is disk only, which stops the revision re-run
    /// from fetching what just landed.
    var revalidateAfter: TimeInterval = 60
    /// How long after a failed revalidation the key is left alone, so a
    /// screen re-rendering on a weak link doesn't ask again every pass.
    var retryAfter: TimeInterval = 15

    private var inFlight: [LibraryKey: Task<any Sendable, Error>] = [:]
    /// When a revalidation last failed, per key, for `retryAfter`.
    private var failedAt: [LibraryKey: Date] = [:]
    /// Every key read this session, what `attach` brings up to date.
    private var loadedKeys: Set<LibraryKey> = []
    private var failureHandler: (@Sendable (Error, PlexLibrary) async -> Void)?
    /// Bumped as each saved copy lands.
    public private(set) var revision = 0

    public nonisolated let changes: AsyncStream<LibraryKey>
    private nonisolated let changeContinuation: AsyncStream<LibraryKey>.Continuation
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Library")

    public init(id: LibraryID, store: OfflineStore, token: String?, record: ServerRecord?) {
        self.id = id
        self.store = store
        self.token = token
        recordBox = Mutex(record)
        (changes, changeContinuation) = AsyncStream.makeStream(of: LibraryKey.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Connection

    public nonisolated var connection: PlexLibrary? { connectionBox.withLock { $0 } }
    public nonisolated var isConnected: Bool { connection != nil }
    public nonisolated var serverURL: URL? { connection?.baseURL }
    public nonisolated var serverIdentifier: String { id.server }
    public nonisolated var record: ServerRecord? { recordBox.withLock { $0 } }

    /// Discovery found the server: every key a screen has read is asked
    /// for again, floor or not, so the first seconds after a connect bring
    /// what is on screen up to date without a pull.
    public func attach(_ connection: PlexLibrary, record: ServerRecord? = nil) {
        connectionBox.withLock { $0 = connection }
        if let record { recordBox.withLock { $0 = record } }
        logger.notice("attached \(connection.baseURL.host() ?? "?", privacy: .public)")
        refresh(Array(loadedKeys))
    }

    /// Nothing answers. Saved copies keep serving; a miss throws.
    public func detach() {
        guard connection != nil else { return }
        connectionBox.withLock { $0 = nil }
        logger.notice("detached")
    }

    /// A revalidation failed on the transport: the monitor decides whether
    /// the server moved or went away. Called at most once per failed fetch,
    /// and never for a connection that has already been replaced.
    public func onConnectionFailure(_ handler: (@Sendable (Error, PlexLibrary) async -> Void)?) {
        failureHandler = handler
    }

    // MARK: - Reads

    public func musicSections() async throws -> [PlexSection] {
        if let connection { return try await connection.musicSections() }
        guard let record else { throw PlexError.offline }
        return record.sections.filter(\.isMusic)
    }

    public func albums(inSection section: String) async throws -> [PlexAlbum] {
        try await read(.albums, saved: await store.load([PlexAlbum].self, for: .albums, server: id.server, section: id.section))
    }

    public func artists(inSection section: String) async throws -> [PlexArtist] {
        try await read(.artists, saved: await store.load([PlexArtist].self, for: .artists, server: id.server, section: id.section))
    }

    /// The saved copy is the last year fetched; `since` filters it.
    public func playHistory(inSection section: String, since: Date) async throws -> [PlayHistoryEntry] {
        let history: [PlayHistoryEntry] = try await read(
            .history, saved: await store.load([PlayHistoryEntry].self, for: .history, server: id.server, section: id.section))
        let stamp = Int(since.timeIntervalSince1970)
        return history.filter { $0.viewedAt >= stamp }
    }

    /// With nothing saved for the artist and no server, the section's
    /// album list answers, as the snapshot did.
    public func albums(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexAlbum] {
        let key = LibraryKey.artistAlbums(artistRatingKey)
        let saved = await store.load([PlexAlbum].self, for: key, server: id.server)
        if saved == nil, connection == nil,
           let all = await store.load([PlexAlbum].self, for: .albums, server: id.server, section: id.section) {
            return all.filter { $0.parentRatingKey == artistRatingKey }
        }
        return try await read(key, saved: saved)
    }

    /// The saved list, or the pinned tracks and favorites on the album
    /// for one reached only through those.
    public func tracks(inAlbum albumRatingKey: String) async throws -> [PlexTrack] {
        try await read(.albumTracks(albumRatingKey), saved: await store.tracks(inAlbum: albumRatingKey, server: id.server))
    }

    public func track(ratingKey: String) async throws -> PlexTrack? {
        if let connection { return try await connection.track(ratingKey: ratingKey) }
        return await store.pinnedTracks(server: id.server).first { $0.ratingKey == ratingKey }
    }

    /// With nothing saved and no server, what is pinned by the artist.
    public func tracks(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexTrack] {
        let key = LibraryKey.artistTracks(artistRatingKey)
        let saved = await store.load([PlexTrack].self, for: key, server: id.server)
        if saved == nil, connection == nil {
            var seen: Set<String> = []
            return await store.pinnedTracks(server: id.server).filter {
                $0.grandparentRatingKey == artistRatingKey && seen.insert($0.ratingKey).inserted
            }
        }
        return try await read(key, saved: saved)
    }

    /// Never saved: megabytes for one rarely used page. Offline it is
    /// everything on disk under a pin, each track once.
    public func tracks(inSection section: String) async throws -> [PlexTrack] {
        if let connection { return try await connection.tracks(inSection: id.section) }
        var seen: Set<String> = []
        return await store.pinnedTracks(server: id.server).filter { seen.insert($0.ratingKey).inserted }
    }

    public func favoriteTracks(inSection section: String) async throws -> [PlexTrack] {
        try await read(.favorites, saved: await store.load([PlexTrack].self, for: .favorites, server: id.server, section: id.section))
    }

    /// The server's search, or its word-prefix match over the pinned tracks.
    public func searchTracks(inSection section: String, query: String) async throws -> [PlexTrack] {
        if let connection { return try await connection.searchTracks(inSection: id.section, query: query) }
        return try await tracks(inSection: id.section).filter { LibrarySearch.matches($0, query: query) }
    }

    public func playlists(inSection section: String) async throws -> [PlexPlaylist] {
        try await read(.playlists, saved: await store.load([PlexPlaylist].self, for: .playlists, server: id.server, section: id.section))
    }

    public func items(inPlaylist ratingKey: String) async throws -> [PlaylistItem] {
        try await read(.playlistItems(ratingKey), saved: await store.items(inPlaylist: ratingKey, server: id.server))
    }

    // MARK: - Writes

    /// The server's, then the favorites asked for again so the saved list
    /// follows within the second.
    public func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws {
        guard let connection else { throw PlexError.offline }
        try await connection.setFavorite(ratingKey, favorite)
        await refreshNow([.favorites])
    }

    public func createPlaylist(title: String, trackKeys: [String]) async throws -> PlexPlaylist {
        guard let connection else { throw PlexError.offline }
        let playlist = try await connection.createPlaylist(title: title, trackKeys: trackKeys)
        await refreshNow([.playlists])
        return playlist
    }

    public func add(trackKeys: [String], toPlaylist ratingKey: String) async throws -> Int {
        guard let connection else { throw PlexError.offline }
        let added = try await connection.add(trackKeys: trackKeys, toPlaylist: ratingKey)
        await refreshNow([.playlists, .playlistItems(ratingKey)])
        return added
    }

    public func remove(item playlistItemID: Int, fromPlaylist ratingKey: String) async throws {
        guard let connection else { throw PlexError.offline }
        try await connection.remove(item: playlistItemID, fromPlaylist: ratingKey)
        await refreshNow([.playlists, .playlistItems(ratingKey)])
    }

    public func move(item playlistItemID: Int, after: Int?, inPlaylist ratingKey: String) async throws {
        guard let connection else { throw PlexError.offline }
        try await connection.move(item: playlistItemID, after: after, inPlaylist: ratingKey)
        await refreshNow([.playlistItems(ratingKey)])
    }

    public func renamePlaylist(_ ratingKey: String, title: String) async throws {
        guard let connection else { throw PlexError.offline }
        try await connection.renamePlaylist(ratingKey, title: title)
        await refreshNow([.playlists])
    }

    public func deletePlaylist(_ ratingKey: String) async throws {
        guard let connection else { throw PlexError.offline }
        try await connection.deletePlaylist(ratingKey)
        await store.remove(.playlistItems(ratingKey), server: id.server)
        await refreshNow([.playlists])
    }

    /// Nothing to tell with no server; the play is simply not counted.
    public func reportTimeline(_ track: PlexTrack, state: PlaybackState, time: Double, sessionIdentifier: String) async throws {
        guard let connection else { return }
        try await connection.reportTimeline(track, state: state, time: time, sessionIdentifier: sessionIdentifier)
    }

    // MARK: - URLs

    public nonisolated func streamURL(for track: PlexTrack, quality: StreamQuality, sessionIdentifier: String) -> URL? {
        connection?.streamURL(for: track, quality: quality, sessionIdentifier: sessionIdentifier)
    }

    public nonisolated func trackSource(for track: PlexTrack, quality: StreamQuality) -> TrackSource? {
        connection?.trackSource(for: track, quality: quality)
    }

    /// The stored cover first, whatever size was asked for; then the
    /// server's URL, from the connection or from the address the record
    /// kept, which the image loader's disk cache can still answer.
    public nonisolated func artworkURL(_ thumb: String?, size: Int) -> URL? {
        if let saved = store.artURL(thumb, server: id.server) { return saved }
        if let connection { return connection.artworkURL(thumb, size: size) }
        guard let base = record?.baseURL, let token else { return nil }
        return PlexLibrary.artworkURL(thumb, size: size, base: base, token: token)
    }

    // MARK: - Refresh

    /// Asks the server for these keys now, floor or not, and returns
    /// without waiting: pull to refresh, and the connect.
    public func refresh(_ keys: [LibraryKey]) {
        guard connection != nil else { return }
        for key in keys { revalidate(key) }
    }

    /// The same, waited for; a failure is reported and swallowed, the
    /// saved copy standing.
    public func refreshNow(_ keys: [LibraryKey]) async {
        guard connection != nil else { return }
        let tasks = keys.map { revalidate($0) }
        for task in tasks { _ = try? await task.value }
    }

    /// Whether the saved copy is old enough to ask about, and the last
    /// attempt long enough ago.
    private func isStale(_ key: LibraryKey) async -> Bool {
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < retryAfter { return false }
        guard let savedAt = await store.savedAt(key, server: id.server, section: id.section) else { return true }
        return Date().timeIntervalSince(savedAt) >= revalidateAfter
    }

    /// The saved copy now, the server behind it; or the fetch itself for a
    /// miss with a connection.
    private func read<Value: Codable & Sendable>(_ key: LibraryKey, saved: Value?) async throws -> Value {
        loadedKeys.insert(key)
        if let saved {
            if connection != nil, await isStale(key) { revalidate(key) }
            return saved
        }
        guard connection != nil else { throw PlexError.offline }
        guard let value = try await revalidate(key).value as? Value else {
            throw PlexError.decoding(underlying: "saved \(key) is not \(Value.self)", body: nil)
        }
        return value
    }

    /// One fetch per key at a time; a second asker joins it.
    @discardableResult
    private func revalidate(_ key: LibraryKey) -> Task<any Sendable, Error> {
        if let task = inFlight[key] { return task }
        let section = id.section
        let task: Task<any Sendable, Error> = switch key {
        case .albums: start(key) { try await $0.albums(inSection: section) }
        case .artists: start(key) { try await $0.artists(inSection: section) }
        case .favorites: start(key) { try await $0.favoriteTracks(inSection: section) }
        case .history: start(key) { try await $0.playHistory(inSection: section, since: .now - Rotation.window) }
        case .playlists: start(key) { try await $0.playlists(inSection: section) }
        case .albumTracks(let ratingKey): start(key) { try await $0.tracks(inAlbum: ratingKey) }
        case .artistAlbums(let ratingKey): start(key) { try await $0.albums(forArtist: ratingKey, inSection: section) }
        case .artistTracks(let ratingKey): start(key) { try await $0.tracks(forArtist: ratingKey, inSection: section) }
        case .playlistItems(let ratingKey): start(key) { try await $0.items(inPlaylist: ratingKey) }
        }
        inFlight[key] = task
        return task
    }

    /// The fetch on the connection of the moment. A swap while it runs
    /// leaves the result good, since it is the same server. A transport
    /// failure on the connection still current is reported, and the
    /// report may itself move the connection (the monitor probes and
    /// finds the server elsewhere); either way a failure that leaves a
    /// different connection current is tried once more on it, so a miss
    /// that died on the address the phone just left lands from the one
    /// that answers.
    private func start<Value: Codable & Sendable>(
        _ key: LibraryKey, _ fetch: @escaping @Sendable (PlexLibrary) async throws -> Value
    ) -> Task<any Sendable, Error> {
        guard let connection else { return Task { throw PlexError.offline } }
        return Task {
            defer { inFlight[key] = nil }
            var connection = connection
            var attempts = 0
            while true {
                attempts += 1
                do {
                    let value = try await fetch(connection)
                    await store.save(value, for: key, server: id.server, section: id.section)
                    failedAt[key] = nil
                    revision += 1
                    changeContinuation.yield(key)
                    return value
                } catch {
                    guard Self.isConnectionError(error) else { throw error }
                    if self.connection === connection {
                        failedAt[key] = Date()
                        logger.error("fetch failed \(String(describing: key), privacy: .public): \(String(describing: error), privacy: .public)")
                        await failureHandler?(error, connection)
                    }
                    if let current = self.connection, current !== connection, attempts < 2 {
                        logger.notice("retrying \(String(describing: key), privacy: .public) on the connection that answered")
                        connection = current
                        continue
                    }
                    throw error
                }
            }
        }
    }

    /// A cancelled fetch is the screen going away; an HTTP or decoding
    /// error is the server answering. Neither is the connection's fault.
    static func isConnectionError(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case PlexError.noServerReachable = error { return true }
        return false
    }

    func setFloors(revalidate: TimeInterval, retry: TimeInterval) {
        revalidateAfter = revalidate
        retryAfter = retry
    }

    /// Waits for every fetch in flight, for tests.
    func settle() async {
        while let task = inFlight.values.first {
            _ = try? await task.value
        }
    }
}
