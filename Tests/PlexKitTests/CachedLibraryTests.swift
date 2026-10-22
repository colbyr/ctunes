import Foundation
import Testing
@testable import PlexKit

@Suite("Cached library")
struct CachedLibraryTests {
    typealias Support = CacheTestSupport
    static let id = LibraryID(server: "M", section: "1")
    static let otherBase = URL(string: "https://10-0-0-5.example.plex.direct:32400")!

    /// A server answered from the fixtures by method and a substring of
    /// the URL, first match wins; counts every request; can fail one host
    /// and hold the first request until released.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var routes: [(method: String, match: String, body: String)]
        private var failingHost: String?
        private var gate: DispatchSemaphore?

        init(_ routes: [(String, String, String)]) {
            self.routes = routes.map { (method: $0.0, match: $0.1, body: $0.2) }
        }

        var requests: [String] { lock.withLock { log } }
        func count(_ substring: String) -> Int { requests.filter { $0.contains(substring) }.count }

        func route(_ method: String, _ match: String, _ body: String) {
            lock.withLock { routes.insert((method, match, body), at: 0) }
        }
        func fail(host: String?) { lock.withLock { failingHost = host } }
        /// Holds the next request until `release`.
        func hold() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            lock.withLock { self.gate = gate }
            return gate
        }

        var handler: @Sendable (URLRequest) -> MockURLProtocol.Response {
            { [self] request in
                let method = request.httpMethod ?? "GET"
                let url = request.url?.absoluteString ?? ""
                let (gate, failing, routes) = lock.withLock {
                    let held = self.gate
                    self.gate = nil
                    log.append("\(method) \(url)")
                    return (held, failingHost, self.routes)
                }
                gate?.wait()
                if let failing, request.url?.host() == failing { return .failing(.cannotConnectToHost) }
                if let route = routes.first(where: { $0.method == method && url.contains($0.match) }) {
                    return .json(route.body)
                }
                return .init(status: 404, body: Data(#"{"MediaContainer":{}}"#.utf8))
            }
        }
    }

    static func fixtureRoutes() throws -> [(String, String, String)] {
        [
            ("GET", "/library/sections/1/albums", try Fixture.string("albums")),
            ("GET", "type=8", try Fixture.string("artists")),
            ("GET", "userRating=10", try Fixture.string("tracks")),
            ("GET", "/status/sessions/history", try Fixture.string("history")),
            ("GET", "/playlists?playlistType", try Fixture.string("playlists")),
            ("GET", "/playlists/440/items", try Fixture.string("playlist-items")),
            ("GET", "/children", try Fixture.string("tracks")),
            ("GET", "type=9&artist.id", try Fixture.string("albums")),
            ("GET", "type=10&artist.id", try Fixture.string("tracks")),
            ("PUT", "/:/rate", #"{"MediaContainer":{}}"#),
            ("PUT", "/playlists/440/items", #"{"MediaContainer":{"leafCountAdded":1}}"#),
        ]
    }

    /// Two albums where the fixture has four, for a list that changed.
    static func shorterAlbums() throws -> String {
        let albums = try JSONDecoder().decode(MediaContainerResponse<PlexAlbum>.self, from: Fixture.data("albums")).items
        let data = try JSONEncoder().encode(Array(albums.prefix(2)))
        return #"{"MediaContainer":{"Metadata":"# + String(decoding: data, as: UTF8.self) + "}}"
    }

    private func connection(_ server: Server, base: URL = Support.base) -> PlexLibrary {
        PlexLibrary(
            client: PlexClient(identity: PlexIdentity(clientIdentifier: "TEST"), session: MockURLProtocol.session(handler: server.handler)),
            server: PlexServer(name: "Test", machineIdentifier: "M", baseURL: base, isLocal: true),
            token: "TOKEN"
        )
    }

    private func make(connected: Bool = true, record: Bool = true) async throws -> (CachedLibrary, Server, OfflineStore) {
        let (cache, root, _) = try Support.makeCache()
        let store = OfflineStore(
            directory: root.appending(path: "Offline"), cache: cache,
            session: MockURLProtocol.session { _ in .init(body: Data(count: 64)) }
        )
        let server = Server(try Self.fixtureRoutes())
        let sections = try JSONDecoder().decode(MediaContainerResponse<PlexSection>.self, from: Fixture.data("sections")).items
        let library = CachedLibrary(
            id: Self.id, store: store, token: "TOKEN",
            record: record ? ServerRecord(name: "Test", sections: sections, baseURL: Support.base) : nil
        )
        if connected { await library.attach(connection(server)) }
        return (library, server, store)
    }

    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []
        func record(_ error: Error) { lock.withLock { errors.append(error) } }
        var count: Int { lock.withLock { errors.count } }
    }

    private func watchFailures(_ library: CachedLibrary) async -> Failures {
        let failures = Failures()
        await library.onConnectionFailure { error, _ in failures.record(error) }
        return failures
    }

    // MARK: - Reads

    @Test("a miss with a connection fetches, saves, and bumps the revision")
    func missFetches() async throws {
        let (library, server, store) = try await make()
        let albums = try await library.albums(inSection: "1")
        #expect(albums.count == 4)
        #expect(server.count("/albums") == 1)
        #expect(await store.load([PlexAlbum].self, for: .albums, server: "M", section: "1") == albums)
        #expect(await library.revision == 1)
        for await key in library.changes {
            #expect(key == .albums)
            break
        }
    }

    @Test("a fresh hit is disk only, across a relaunch too")
    func freshHit() async throws {
        let (library, server, store) = try await make()
        _ = try await library.albums(inSection: "1")
        _ = try await library.albums(inSection: "1")
        #expect(server.count("/albums") == 1)

        let relaunched = CachedLibrary(id: Self.id, store: store, token: "TOKEN", record: nil)
        await relaunched.attach(connection(server))
        #expect(try await relaunched.albums(inSection: "1").count == 4)
        #expect(server.count("/albums") == 1)
    }

    @Test("a stale hit answers from disk and asks the server behind it")
    func staleHit() async throws {
        let (library, server, store) = try await make()
        await library.setFloors(revalidate: 0, retry: 0)
        #expect(try await library.albums(inSection: "1").count == 4)

        server.route("GET", "/library/sections/1/albums", try Self.shorterAlbums())
        #expect(try await library.albums(inSection: "1").count == 4, "the saved copy, now")
        await library.settle()
        #expect(server.count("/albums") == 2)
        #expect(await store.load([PlexAlbum].self, for: .albums, server: "M", section: "1")?.count == 2)
        #expect(try await library.albums(inSection: "1").count == 2)
        #expect(await library.revision == 2)
    }

    @Test("a revalidation that fails keeps the saved copy, reports once, and is not retried every read")
    func failedRevalidation() async throws {
        let (library, server, store) = try await make()
        let failures = await watchFailures(library)
        await library.setFloors(revalidate: 0, retry: 15)
        #expect(try await library.albums(inSection: "1").count == 4)

        server.fail(host: Support.base.host())
        #expect(try await library.albums(inSection: "1").count == 4)
        await library.settle()
        #expect(failures.count == 1)
        #expect(await store.load([PlexAlbum].self, for: .albums, server: "M", section: "1")?.count == 4)

        #expect(try await library.albums(inSection: "1").count == 4)
        await library.settle()
        #expect(server.count("/albums") == 2, "inside the retry floor")
        #expect(failures.count == 1)
    }

    @Test("a miss with no connection is offline, and so is every write")
    func missOffline() async throws {
        let (library, server, _) = try await make(connected: false)
        #expect(!library.isConnected)
        await #expect(throws: PlexError.self) { try await library.albums(inSection: "1") }
        await #expect(throws: PlexError.self) { try await library.setFavorite("1", true) }
        await #expect(throws: PlexError.self) { try await library.renamePlaylist("440", title: "x") }
        #expect(server.requests.isEmpty)
        #expect(try await library.musicSections().count == 2, "the record's")
        let track = Support.track(id: 1, album: "9", artist: "A")
        #expect(library.streamURL(for: track) == nil)
        #expect(library.trackSource(for: track) == nil)
        try await library.reportTimeline(track, state: .playing, time: 0, sessionIdentifier: "s")
    }

    @Test("two readers of one key share one fetch")
    func coalesced() async throws {
        let (library, server, _) = try await make()
        async let first = library.albums(inSection: "1")
        async let second = library.albums(inSection: "1")
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(server.count("/albums") == 1)
    }

    @Test("a detach while a fetch is out still saves what comes back")
    func detachMidFlight() async throws {
        let (library, server, store) = try await make()
        let failures = await watchFailures(library)
        let gate = server.hold()
        let reading = Task { try await library.albums(inSection: "1") }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await library.detach()
        gate.signal()
        #expect(try await reading.value.count == 4)
        #expect(await store.load([PlexAlbum].self, for: .albums, server: "M", section: "1")?.count == 4)
        #expect(failures.count == 0)
        #expect(try await library.albums(inSection: "1").count == 4, "and serves it with no connection")
    }

    @Test("a failure on a connection already replaced is retried on the new one, not reported")
    func failureAfterSwap() async throws {
        let (library, server, _) = try await make()
        let failures = await watchFailures(library)
        server.fail(host: Support.base.host())
        let gate = server.hold()
        let reading = Task { try await library.albums(inSection: "1") }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await library.attach(connection(server, base: Self.otherBase))
        gate.signal()
        #expect(try await reading.value.count == 4)
        #expect(failures.count == 0)
        #expect(server.count("/albums") == 2)
        #expect(server.requests.last?.contains(Self.otherBase.host()!) == true)
    }

    @Test("attach asks again for every key a screen has read, floor or not")
    func attachRefreshes() async throws {
        let (library, server, store) = try await make()
        _ = try await library.albums(inSection: "1")
        await library.detach()
        server.route("GET", "/library/sections/1/albums", try Self.shorterAlbums())
        await library.attach(connection(server))
        await library.settle()
        #expect(server.count("/albums") == 2)
        #expect(await store.load([PlexAlbum].self, for: .albums, server: "M", section: "1")?.count == 2)
    }

    @Test("an artist's albums come from the saved section list when nothing else is there")
    func artistAlbumsOffline() async throws {
        let (library, server, _) = try await make()
        _ = try await library.albums(inSection: "1")
        await library.detach()
        #expect(try await library.albums(forArtist: "2899", inSection: "1").count == 3)
        #expect(try await library.albums(forArtist: "nope", inSection: "1").isEmpty)
        #expect(server.count("artist.id") == 0)
        await library.attach(connection(server))
        #expect(try await library.albums(forArtist: "2899", inSection: "1").count == 4, "the server's answer, saved")
        await library.detach()
        #expect(try await library.albums(forArtist: "2899", inSection: "1").count == 4)
    }

    @Test("the saved history is a year; the caller's window filters it")
    func history() async throws {
        let (library, server, _) = try await make()
        #expect(try await library.playHistory(inSection: "1", since: .distantPast).count == 9)
        #expect(try await library.playHistory(inSection: "1", since: Date(timeIntervalSince1970: 1_788_827_321)).count == 1)
        #expect(try await library.playHistory(inSection: "1", since: .now).isEmpty)
        #expect(server.count("history") == 1)
    }

    @Test("favorites are asked for again after a heart")
    func heartRefreshes() async throws {
        let (library, server, store) = try await make()
        #expect(try await library.favoriteTracks(inSection: "1").count == 7)
        server.route("GET", "userRating=10", #"{"MediaContainer":{"Metadata":[]}}"#)
        try await library.setFavorite("1030", false)
        #expect(server.count("/:/rate") == 1)
        #expect(server.count("userRating=10") == 2)
        #expect(await store.load([PlexTrack].self, for: .favorites, server: "M", section: "1")?.isEmpty == true)
        #expect(try await library.favoriteTracks(inSection: "1").isEmpty)
    }

    @Test("a playlist write refreshes the list and the items")
    func playlistWrite() async throws {
        let (library, server, _) = try await make()
        #expect(try await library.add(trackKeys: ["1030"], toPlaylist: "440") == 1)
        #expect(server.count("GET https://example.plex.direct:32400/playlists?playlistType") == 1)
        #expect(server.count("GET https://example.plex.direct:32400/playlists/440/items") == 1)
        #expect(try await library.items(inPlaylist: "440").count > 0)
        #expect(server.count("GET https://example.plex.direct:32400/playlists/440/items") == 1, "saved by the refresh")
    }

    @Test("with no connection, pinned albums and favorites answer by album and by artist")
    func pinnedFallbacks() async throws {
        let (library, _, store) = try await make(connected: false)
        let sources: @Sendable (PlexTrack) -> TrackSource? = { track in
            track.part.flatMap { $0.cacheKey == nil ? nil : Support.source(part: $0) }
        }
        let first = [Support.track(id: 1, album: "9", artist: "A"), Support.track(id: 2, album: "9", artist: "A")]
        let second = [Support.track(id: 3, album: "8", artist: "B")]
        let favorite = Support.track(id: 4, album: "7", artist: "A")
        for (album, tracks) in [("9", first), ("8", second)] {
            await store.pinAlbum(
                PlexAlbum(ratingKey: album, title: "Album", parentRatingKey: tracks[0].grandparentRatingKey, parentTitle: "Artist", year: nil, thumb: nil),
                tracks: tracks, server: "M", section: "1", art: { _ in nil }, sources: sources)
        }
        await store.setFavoritesPinned(true, server: "M", section: "1")
        await store.setFavorites([favorite, first[0]], server: "M", section: "1", sources: sources)

        #expect(try await library.tracks(inAlbum: "9") == first)
        #expect(try await library.tracks(inAlbum: "7") == [favorite], "reached through the favorites alone")
        await #expect(throws: PlexError.self) { try await library.tracks(inAlbum: "nope") }
        #expect(try await library.tracks(forArtist: "A", inSection: "1") == first + [favorite])
        #expect(try await library.tracks(forArtist: "B", inSection: "1") == second)
        #expect(try await library.favoriteTracks(inSection: "1") == [favorite, first[0]])
        #expect(try await library.tracks(inSection: "1").count == 4)
        #expect(try await library.searchTracks(inSection: "1", query: "track 3") == second)
        #expect(try await library.track(ratingKey: "4") == favorite)
    }

    @Test("artwork is the saved file, then the connection's URL, then the record's address")
    func artwork() async throws {
        let (library, server, _) = try await make()
        let thumb = "/library/metadata/9/thumb/1"
        let online = try #require(library.artworkURL(thumb, size: 200))
        #expect(online.absoluteString.hasPrefix(Support.base.absoluteString + "/photo/:/transcode"))
        await library.detach()
        #expect(library.artworkURL(thumb, size: 200) == online, "the record's address, the same URL")
        let root = try Support.makeDirectory()
        let bare = CachedLibrary(id: Self.id, store: OfflineStore(directory: root.appending(path: "o"), cache: TrackCache(
            directory: root.appending(path: "c"), pinnedDirectory: root.appending(path: "p"), session: .shared)), token: "TOKEN", record: nil)
        #expect(bare.artworkURL(thumb, size: 200) == nil)
        _ = server
    }
}
