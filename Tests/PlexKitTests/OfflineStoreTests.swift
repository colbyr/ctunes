import Foundation
import Testing
@testable import PlexKit

@Suite("Offline store")
struct OfflineStoreTests {
    typealias Support = CacheTestSupport
    private static let server = "M"

    private func makeStore(
        limit: Int = 2 << 30,
        body: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response = { _ in
            .init(body: Data(count: 1024))
        }
    ) throws -> (OfflineStore, TrackCache, Support.Counter) {
        let (cache, root, counter) = try Support.makeCache(limit: limit, body: body)
        let store = OfflineStore(
            directory: root.appending(path: "Offline"),
            cache: cache,
            session: MockURLProtocol.session { _ in .init(body: Data(count: 64)) }
        )
        return (store, cache, counter)
    }

    private let sources: @Sendable (PlexTrack) -> TrackSource? = { track in
        track.part.flatMap { $0.cacheKey == nil ? nil : Support.source(part: $0) }
    }

    private func album(_ key: String, artist: String = "A", thumb: String? = nil) -> PlexAlbum {
        PlexAlbum(ratingKey: key, title: "Album \(key)", parentRatingKey: artist,
                  parentTitle: "Artist", year: 2020, thumb: thumb, genres: ["Pop/Rock"])
    }

    private func tracks(_ ids: [Int], album: String, artist: String = "A") -> [PlexTrack] {
        ids.map { Support.track(id: $0, album: album, artist: artist) }
    }

    private func path(_ id: Int) -> String { "M/\(id)-1746246593.flac" }

    private func pin(_ store: OfflineStore, _ album: PlexAlbum, _ tracks: [PlexTrack]) async {
        await store.pinAlbum(album, tracks: tracks, server: Self.server, section: "1", art: { _ in nil }, sources: sources)
    }

    // MARK: - Snapshot

    @Test("an album with genres round-trips through JSON")
    func albumRoundTrip() throws {
        let original = try JSONDecoder().decode(
            MediaContainerResponse<PlexAlbum>.self, from: Fixture.data("albums")
        ).items
        #expect(original.contains { !$0.genres.isEmpty })
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([PlexAlbum].self, from: data)
        #expect(decoded == original)
    }

    @Test("a snapshot built from the fixtures survives save and load")
    func snapshotRoundTrip() async throws {
        let (store, _, _) = try makeStore()
        let snapshot = try Self.fixtureSnapshot()
        try await store.save(snapshot)
        #expect(await store.snapshot(server: Self.server, section: "1") == snapshot)
        #expect(await store.snapshot(server: Self.server, section: nil) == snapshot)
        #expect(await store.snapshot(server: Self.server, section: "2") == nil)
        #expect(await store.snapshot(server: "N", section: nil) == nil)
    }

    @Test("nothing on disk carries a token")
    func nothingSecretOnDisk() async throws {
        let (store, _, _) = try makeStore()
        try await store.save(try Self.fixtureSnapshot())
        await pin(store, album("1029"), tracks([1, 2], album: "1029"))
        let files = (FileManager.default.subpaths(atPath: store.directory.path) ?? [])
            .filter { $0.hasSuffix(".json") }
        #expect(files.count >= 3)
        for file in files {
            let text = try String(contentsOf: store.directory.appending(path: file), encoding: .utf8)
            #expect(!text.contains("X-Plex-Token"), "\(file)")
            #expect(!text.contains("tok"), "\(file)")
        }
    }

    static func fixtureSnapshot() throws -> LibrarySnapshot {
        let sections = try JSONDecoder().decode(MediaContainerResponse<PlexSection>.self, from: Fixture.data("sections")).items
        let albums = try JSONDecoder().decode(MediaContainerResponse<PlexAlbum>.self, from: Fixture.data("albums")).items
        let artists = try JSONDecoder().decode(MediaContainerResponse<PlexArtist>.self, from: Fixture.data("artists")).items
        let tracks = try JSONDecoder().decode(MediaContainerResponse<PlexTrack>.self, from: Fixture.data("tracks")).items
        let section = try #require(sections.first { $0.key == "1" })
        return LibrarySnapshot(
            server: server, serverName: "Test", sections: sections, section: section,
            albums: albums, artists: artists, favorites: Array(tracks.prefix(2)),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000), baseURL: Support.base
        )
    }

    // MARK: - Pins

    @Test("pinning an album downloads it in order into the pinned root")
    func pinDownloads() async throws {
        let (store, cache, counter) = try makeStore()
        let tracks = tracks([3, 1, 2], album: "9")
        await pin(store, album("9"), tracks)
        try await cache.drain()

        #expect(counter.requests == tracks.map { $0.part!.key })
        for track in tracks {
            let url = try #require(cache.localURL(server: Self.server, part: track.part!))
            #expect(url.path.hasPrefix(cache.pinnedDirectory.path))
            #expect(cache.isPinned(server: Self.server, part: track.part!))
        }
        #expect(await cache.usage() == 0)
        #expect(await cache.pinnedUsage() == 3 * 1024)
        #expect(await store.pinnedAlbumKeys(server: Self.server) == ["9"])
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == tracks)
    }

    @Test("a track already in the cache root is renamed, not fetched again")
    func pinRenamesCached() async throws {
        let (store, cache, counter) = try makeStore()
        let track = tracks([1], album: "9")[0]
        try await cache.download(sources(track)!)
        #expect(counter.count == 1)

        await pin(store, album("9"), [track])
        try await cache.drain()

        #expect(counter.count == 1)
        #expect(cache.isPinned(server: Self.server, part: track.part!))
        #expect(await cache.usage() == 0)
    }

    @Test("the window is served before the pin queue")
    func windowFirst() async throws {
        let (store, cache, counter) = try makeStore { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .init(body: Data(count: 1024))
        }
        await pin(store, album("9"), tracks([1, 2, 3], album: "9"))
        try await Task.sleep(for: .milliseconds(10))
        await cache.retain(window: [Support.source(id: 50)])
        try await cache.drain()

        let requests = counter.requests
        #expect(requests.count == 4)
        #expect(requests[1].contains("/50/"), "\(requests)")
    }

    @Test("retain does not cancel an in-flight pin")
    func retainLeavesPins() async throws {
        let (store, cache, _) = try makeStore { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .init(body: Data(count: 1024))
        }
        let track = tracks([1], album: "9")[0]
        await pin(store, album("9"), [track])
        try await Task.sleep(for: .milliseconds(50))
        await cache.retain(window: [Support.source(id: 50)])
        try await cache.drain()
        #expect(cache.isPinned(server: Self.server, part: track.part!))
    }

    @Test("eviction never reaches the pinned root")
    func evictionSkipsPins() async throws {
        let (store, cache, _) = try makeStore(limit: 0)
        let pinnedTracks = tracks([1, 2], album: "9")
        await pin(store, album("9"), pinnedTracks)
        try await cache.drain()
        try await cache.download(Support.source(id: 50))
        try await cache.download(Support.source(id: 51))

        #expect(await cache.usage() == 0)
        #expect(await cache.pinnedUsage() == 2 * 1024)
    }

    @Test("unpinning moves files back to the cache root unless favorites still want them")
    func unpinShared() async throws {
        let (store, cache, _) = try makeStore()
        let shared = Support.track(id: 1, album: "9", artist: "A")
        let only = Support.track(id: 2, album: "9", artist: "A")
        await pin(store, album("9"), [shared, only])
        await store.setFavoritesPinned(true, server: Self.server)
        await store.setFavorites([shared], server: Self.server, sources: sources)
        try await cache.drain()

        await store.unpinAlbum("9", server: Self.server)

        #expect(cache.isPinned(server: Self.server, part: shared.part!))
        #expect(!cache.isPinned(server: Self.server, part: only.part!))
        #expect(cache.localURL(server: Self.server, part: only.part!) != nil, "back in the cache root")
        #expect(await store.pinnedAlbumKeys(server: Self.server).isEmpty)
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == [shared, only], "the list outlives the pin")
    }

    @Test("a browsed album's tracks are remembered and count as available once a file is cached")
    func browsedAlbum() async throws {
        let (store, cache, _) = try makeStore()
        let tracks = tracks([1, 2], album: "9")
        await store.saveTracks(tracks, inAlbum: "9", server: Self.server)
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == tracks)
        #expect(await store.tracks(inAlbum: "8", server: Self.server) == nil)
        #expect(await store.availableAlbums(server: Self.server).isEmpty)

        try await cache.download(sources(tracks[1])!)
        #expect(await store.availableAlbums(server: Self.server) == ["9"])
        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.state(of: album("9")) == .none, "browsed, not pinned: the file is in the cache root")
        #expect(inventory.statuses["9"] == .init(artistKey: "A", known: 2), "but the list counts toward the artist")
    }

    @Test("offline artwork falls back to the server URL the image cache saw")
    func artworkFallback() async throws {
        let (store, _, _) = try makeStore()
        let snapshot = try Self.fixtureSnapshot()
        let library = OfflineLibrary(snapshot: snapshot, store: store, token: "tok")
        let url = try #require(library.artworkURL("/library/metadata/9/thumb/1", size: 200))
        #expect(url.absoluteString.hasPrefix(Support.base.absoluteString + "/photo/:/transcode"))
        #expect(OfflineLibrary(snapshot: snapshot, store: store).artworkURL("/x", size: 200) == nil, "no token, no URL")
    }

    @Test("replacing the favorites group pins the new and unpins the dropped")
    func favoritesDiff() async throws {
        let (store, cache, counter) = try makeStore()
        let a = Support.track(id: 1, album: "9", artist: "A")
        let b = Support.track(id: 2, album: "9", artist: "A")
        let c = Support.track(id: 3, album: "9", artist: "A")
        await store.setFavoritesPinned(true, server: Self.server)
        await store.setFavorites([a, b], server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 2)

        await store.setFavorites([b, c], server: Self.server, sources: sources)
        try await cache.drain()

        #expect(counter.count == 3)
        #expect(!cache.isPinned(server: Self.server, part: a.part!))
        #expect(cache.isPinned(server: Self.server, part: b.part!))
        #expect(cache.isPinned(server: Self.server, part: c.part!))
        #expect(await store.favoriteTracks(server: Self.server) == [b, c])

        await store.setFavoritesPinned(false, server: Self.server)
        #expect(!cache.isPinned(server: Self.server, part: b.part!))
        #expect(await cache.usage() == 3 * 1024)
    }

    @Test("favorites are ignored until the pin is on")
    func favoritesOff() async throws {
        let (store, cache, counter) = try makeStore()
        await store.setFavorites(tracks([1], album: "9"), server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 0)
    }

    // MARK: - Status

    @Test("statuses: pending, complete and partial")
    func statuses() async throws {
        let (store, cache, _) = try makeStore()
        let whole = tracks([1, 2], album: "9")
        let mixed = [
            Support.track(id: 3, album: "8", artist: "A"),
            Support.track(id: 4, album: "8", artist: "A", key: "/music/:/transcode/universal/start.m3u8"),
        ]
        await pin(store, album("9"), whole)
        await pin(store, album("8"), mixed)
        try await cache.drain()

        var inventory = await store.inventory(server: Self.server)
        #expect(inventory.state(of: album("9")) == .complete(undownloadable: 0))
        #expect(inventory.state(of: album("8")) == .complete(undownloadable: 1))
        #expect(inventory.statuses["9"] == .init(artistKey: "A", done: 2, known: 2, bytes: 2048, pinned: true))

        await cache.evict(server: Self.server, part: whole[0].part!)
        inventory = await store.inventory(server: Self.server)
        #expect(inventory.state(of: album("9")) == .downloading(done: 1, total: 2, stalled: false))
        #expect(inventory.state(ofArtist: "A", albums: [album("9"), album("8")]) == .downloading(done: 2, total: 4, stalled: false))
    }

    @Test("a failed track leaves the album pending and resume retries it after the backoff")
    func failureMemo() async throws {
        let (store, cache, counter) = try makeStore { request in
            request.url!.path.contains("/2/") ? .init(status: 500, body: Data()) : .init(body: Data(count: 1024))
        }
        let tracks = tracks([1, 2, 3], album: "9")
        await pin(store, album("9"), tracks)
        try await cache.drain()
        #expect(counter.count == 3)
        let stalled = await store.inventory(server: Self.server).state(of: album("9"))
        #expect(stalled == .downloading(done: 2, total: 3, stalled: true))
        #expect(stalled.isStalled)

        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 3, "within the backoff")

        await cache.setRetryAfter(0)
        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 4)
    }

    @Test("retryFailed drops the backoff so resume fetches again at once")
    func retryFailed() async throws {
        let (store, cache, counter) = try makeStore { _ in .init(status: 500, body: Data()) }
        await pin(store, album("9"), tracks([1], album: "9"))
        try await cache.drain()
        #expect(counter.count == 1)
        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 1)

        await cache.retryFailed()
        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 2)
    }

    @Test("an album reached only through pinned favorites is available and has a page")
    func favoritesAlbum() async throws {
        let (store, cache, _) = try makeStore()
        let favorite = Support.track(id: 1, album: "9", artist: "A")
        await store.setFavoritesPinned(true, server: Self.server)
        await store.setFavorites([favorite], server: Self.server, sources: sources)
        try await cache.drain()

        #expect(await store.availableAlbums(server: Self.server) == ["9"], "never browsed, still playable")
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == [favorite])
        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.statuses["9"] == .init(artistKey: "A", done: 1, known: 0, bytes: 1024, pinned: false), "favorites are not an album pin")
        #expect(inventory.state(of: album("9")) == .complete(undownloadable: 0), "no track count known")
        #expect(inventory.state(of: PlexAlbum(ratingKey: "9", title: "", parentTitle: nil, year: nil, thumb: nil, leafCount: 10)) == .partial(done: 1, total: 10))
        #expect(!inventory.isTrackPinned(favorite), "a heart is not a pin")
    }

    @Test("resume rebuilds pins from disk on a fresh store")
    func resumeAfterRelaunch() async throws {
        let (store, cache, counter) = try makeStore()
        await pin(store, album("9"), tracks([1, 2], album: "9"))
        try await cache.drain()
        await cache.evict(server: Self.server, part: Support.part(id: 2))

        let relaunched = OfflineStore(directory: store.directory, cache: cache)
        await relaunched.resume(server: Self.server, sources: sources)
        try await cache.drain()

        #expect(counter.count == 3)
        #expect(await relaunched.inventory(server: Self.server).state(of: album("9")) == .complete(undownloadable: 0))
    }

    // MARK: - Offline library

    @Test("the offline library serves pinned albums and favorites by artist")
    func offlineLibrary() async throws {
        let (store, cache, _) = try makeStore()
        let first = tracks([1, 2], album: "9", artist: "A")
        let second = tracks([3], album: "8", artist: "B")
        let favorite = Support.track(id: 4, album: "7", artist: "A")
        await pin(store, album("9", artist: "A"), first)
        await pin(store, album("8", artist: "B"), second)
        await store.setFavoritesPinned(true, server: Self.server)
        await store.setFavorites([favorite, first[0]], server: Self.server, sources: sources)
        try await cache.drain()

        let snapshot = try Self.fixtureSnapshot()
        let library = OfflineLibrary(snapshot: snapshot, store: store)

        #expect(library.isOffline)
        #expect(library.serverIdentifier == Self.server)
        #expect(try await library.tracks(inAlbum: "9") == first)
        #expect(try await library.tracks(inAlbum: "nope") == [])
        #expect(try await library.tracks(forArtist: "A", inSection: "1") == first + [favorite])
        #expect(try await library.tracks(forArtist: "B", inSection: "1") == second)
        #expect(try await library.albums(inSection: "1") == snapshot.albums)
        #expect(try await library.albums(forArtist: "2899", inSection: "1").count == 3)
        #expect(try await library.favoriteTracks(inSection: "1") == snapshot.favorites)
        #expect(library.streamURL(for: first[0]) == nil)
        #expect(library.trackSource(for: first[0]) == nil)
        await #expect(throws: PlexError.self) { try await library.setFavorite("1", true) }
    }

    @Test("album art is saved at pin time and served as a file URL")
    func art() async throws {
        let (store, cache, _) = try makeStore()
        let thumb = "/library/metadata/9/thumb/1746246600"
        #expect(store.artURL(thumb, server: Self.server) == nil)
        await store.pinAlbum(
            album("9", thumb: thumb), tracks: tracks([1], album: "9"), server: Self.server, section: "1",
            art: { _ in Support.base.appending(path: "/photo/:/transcode") }, sources: sources
        )
        try await cache.drain()
        let url = try #require(store.artURL(thumb, server: Self.server))
        #expect(url.isFileURL)
        #expect(url.lastPathComponent == "library-metadata-9-thumb-1746246600.jpg")
        #expect(await store.usage() == 1024 + 64)
    }

    @Test("clear empties the manifest, the snapshot and the pinned root")
    func clear() async throws {
        let (store, cache, _) = try makeStore()
        try await store.save(try Self.fixtureSnapshot())
        await pin(store, album("9"), tracks([1], album: "9"))
        try await cache.drain()
        #expect(await cache.pinnedUsage() == 1024)

        await store.clear()

        #expect(await cache.pinnedUsage() == 0)
        #expect(await store.pinnedAlbumKeys(server: Self.server).isEmpty)
        #expect(await store.snapshot(server: Self.server, section: nil) == nil)
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        #expect(leftover.isEmpty, "\(leftover)")
    }

    // MARK: - Artist and track pins

    private func pinArtist(_ store: OfflineStore, key: String = "A", albums: [PlexAlbum], tracks: [PlexTrack]) async {
        await store.pinArtist(key: key, title: "Artist", thumb: nil, albums: albums, tracks: tracks,
                              server: Self.server, section: "1", art: { _ in nil }, sources: sources)
    }

    @Test("pinning an artist downloads every album in order and absorbs the pins under it")
    func pinArtistAbsorbs() async throws {
        let (store, cache, counter) = try makeStore()
        let first = tracks([1, 2], album: "9")
        let second = tracks([3, 4], album: "8")
        await pin(store, album("8"), second)
        await store.pinTracks([first[1]], server: Self.server, art: { _ in nil }, sources: sources)
        try await cache.drain()
        #expect(counter.count == 3)

        // The artist's list arrives in one fetch, in no particular order.
        await pinArtist(store, albums: [album("9"), album("8")], tracks: second + first.reversed())
        try await cache.drain()

        #expect(counter.count == 4, "only the one missing file")
        #expect(counter.requests.last == first[0].part!.key)
        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.artists.map(\.key) == ["A"])
        #expect(inventory.artists[0].albums == [album("9"), album("8")])
        #expect(inventory.albums.isEmpty, "the album pin folded into the artist")
        #expect(inventory.tracks.isEmpty, "so did the track pin")
        #expect(inventory.isAlbumPinned("9") && inventory.isAlbumPinned("8"))
        #expect(inventory.isTrackPinned(first[0]))
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == first, "filed in track order")
        #expect(inventory.state(ofArtist: "A", albums: [album("9"), album("8")]) == .complete(undownloadable: 0))
        #expect(await store.pinnedAlbumKeys(server: Self.server) == ["9", "8"])
    }

    @Test("removing an album under an artist pin narrows the pin to the other albums")
    func unpinAlbumNarrowsArtist() async throws {
        let (store, cache, _) = try makeStore()
        let first = tracks([1], album: "9")
        let second = tracks([2], album: "8")
        let third = tracks([3], album: "7")
        await pinArtist(store, albums: [album("9"), album("8"), album("7")], tracks: first + second + third)
        try await cache.drain()

        await store.unpinAlbum("8", server: Self.server)

        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.artists.isEmpty)
        #expect(inventory.albums.map(\.id) == ["9", "7"])
        #expect(inventory.albums.map(\.album) == [album("9"), album("7")])
        #expect(!cache.isPinned(server: Self.server, part: second[0].part!))
        #expect(cache.localURL(server: Self.server, part: second[0].part!) != nil, "back in the cache root")
        #expect(cache.isPinned(server: Self.server, part: first[0].part!))
        #expect(cache.isPinned(server: Self.server, part: third[0].part!))
        #expect(inventory.state(ofArtist: "A", albums: [album("9"), album("8"), album("7")]) == .partial(done: 2, total: 3))
        #expect(inventory.state(of: album("8")) == .none)

        await store.unpinArtist("A", server: Self.server)
        #expect(await store.inventory(server: Self.server).albums.isEmpty, "the album pins were theirs too")
        #expect(!cache.isPinned(server: Self.server, part: first[0].part!))
    }

    @Test("removing an artist with no artist pin still drops their album and track pins")
    func unpinArtistByAlbums() async throws {
        let (store, cache, _) = try makeStore()
        let mine = tracks([1], album: "9", artist: "A")
        let loose = tracks([2], album: "8", artist: "A")
        let other = tracks([3], album: "7", artist: "B")
        await pin(store, album("9", artist: "A"), mine)
        await store.pinTracks(loose, server: Self.server, art: { _ in nil }, sources: sources)
        await pin(store, album("7", artist: "B"), other)
        try await cache.drain()

        await store.unpinArtist("A", server: Self.server)

        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.albums.map(\.id) == ["7"])
        #expect(inventory.tracks.isEmpty)
        #expect(!cache.isPinned(server: Self.server, part: mine[0].part!))
        #expect(!cache.isPinned(server: Self.server, part: loose[0].part!))
        #expect(cache.isPinned(server: Self.server, part: other[0].part!))
    }

    @Test("removing a track narrows the album pin to its other tracks, and the artist pin above it first")
    func unpinTrackNarrows() async throws {
        let (store, cache, _) = try makeStore()
        let first = tracks([1, 2, 3], album: "9")
        let second = tracks([4], album: "8")
        await pinArtist(store, albums: [album("9"), album("8")], tracks: first + second)
        try await cache.drain()

        await store.unpinTrack(first[1], server: Self.server)

        var inventory = await store.inventory(server: Self.server)
        #expect(inventory.artists.isEmpty)
        #expect(inventory.albums.map(\.id) == ["8"])
        #expect(inventory.tracks == [first[0], first[2]])
        #expect(!cache.isPinned(server: Self.server, part: first[1].part!))
        #expect(cache.isPinned(server: Self.server, part: first[0].part!))
        #expect(cache.isPinned(server: Self.server, part: second[0].part!))
        #expect(inventory.state(of: album("9")) == .partial(done: 2, total: 3))
        #expect(!inventory.isAlbumPinned("9"))
        #expect(inventory.isTrackPinned(first[0]) && !inventory.isTrackPinned(first[1]))

        await store.unpinTrack(first[0], server: Self.server)
        inventory = await store.inventory(server: Self.server)
        #expect(inventory.tracks == [first[2]])
        #expect(inventory.state(of: album("9")) == .partial(done: 1, total: 3))
    }

    @Test("a track pin is skipped under an album pin, and an album pin absorbs the track pins on it")
    func trackPins() async throws {
        let (store, cache, counter) = try makeStore()
        let tracks = tracks([1, 2, 3], album: "9")
        await store.pinTracks([tracks[0], tracks[0]], server: Self.server, art: { _ in nil }, sources: sources)
        try await cache.drain()
        #expect(counter.count == 1)
        var inventory = await store.inventory(server: Self.server)
        #expect(inventory.tracks == [tracks[0]], "once")
        #expect(inventory.isTrackPinned(tracks[0]) && !inventory.isTrackPinned(tracks[1]))
        #expect(inventory.bytes(for: tracks[0], server: Self.server) == 1024)
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == [tracks[0]], "a page from the pin alone")

        await pin(store, album("9"), tracks)
        try await cache.drain()
        inventory = await store.inventory(server: Self.server)
        #expect(inventory.tracks.isEmpty)
        #expect(inventory.albums.map(\.id) == ["9"])

        await store.pinTracks([tracks[1]], server: Self.server, art: { _ in nil }, sources: sources)
        #expect(await store.inventory(server: Self.server).tracks.isEmpty, "covered already")
        #expect(counter.count == 3)
    }

    @Test("a manifest from before artist pins still reads, and its pins gain an album record")
    func manifestMigration() async throws {
        let (store, cache, _) = try makeStore()
        let tracks = tracks([1], album: "9")
        await store.saveTracks(tracks, inAlbum: "9", server: Self.server)
        let old = """
        {"albums":{"9":{"title":"Album 9","section":"1","pinnedAt":"2025-01-01T00:00:00Z"}},"favoritesPinned":true}
        """
        try Data(old.utf8).write(to: store.directory.appending(path: "M/manifest.json"))

        let fresh = OfflineStore(directory: store.directory, cache: cache)
        await fresh.resume(server: Self.server, sources: sources)
        try await cache.drain()

        let inventory = await fresh.inventory(server: Self.server)
        #expect(inventory.artists.isEmpty)
        #expect(inventory.favoritesPinned)
        #expect(inventory.albums.count == 1)
        #expect(inventory.albums[0].album.ratingKey == "9")
        #expect(inventory.albums[0].album.parentRatingKey == "A")
        #expect(inventory.albums[0].album.leafCount == 1)
        #expect(inventory.state(of: inventory.albums[0].album) == .complete(undownloadable: 0))
    }

    @Test("the inventory tells a download in flight from one that stalled, per track")
    func inventoryProgress() async throws {
        let (store, cache, _) = try makeStore { request in
            request.url!.path.contains("/2/") ? .init(status: 500, body: Data()) : .init(body: Data(count: 1024))
        }
        let tracks = tracks([1, 2], album: "9")
        await pin(store, album("9"), tracks)
        try await cache.drain()

        let inventory = await store.inventory(server: Self.server)
        #expect(inventory.isDownloaded(tracks[0], server: Self.server))
        #expect(!inventory.isDownloaded(tracks[1], server: Self.server))
        #expect(inventory.isDownloading(tracks[1], server: Self.server))
        #expect(inventory.isFailed(tracks[1], server: Self.server))
        #expect(inventory.usage(of: tracks, server: Self.server) == (1024, 1))
        #expect(inventory.totalBytes == 1024)
        #expect(inventory.state(of: album("9")) == .downloading(done: 1, total: 2, stalled: true))
    }

    @Test("download states roll up from counts")
    func states() {
        typealias R = DownloadState.Rollup
        #expect(DownloadState(R()) == .none)
        #expect(DownloadState(R(done: 0, total: 3, missing: 3)) == .downloading(done: 0, total: 3, stalled: false))
        #expect(DownloadState(R(done: 2, total: 3, missing: 1, failed: 1)) == .downloading(done: 2, total: 3, stalled: true))
        #expect(DownloadState(R(done: 1, total: 3)) == .partial(done: 1, total: 3))
        #expect(DownloadState(R(done: 3, total: 3)) == .complete(undownloadable: 0))
        #expect(DownloadState(R(done: 2, total: 3, undownloadable: 1)) == .complete(undownloadable: 1))
        #expect(DownloadState(R(done: 0, total: 3, missing: 1)).hasFiles == false)
        #expect(DownloadState(R(done: 1, total: 3, missing: 1)).hasFiles)

        // An album never browsed: leafCount fills in the total.
        let status = AlbumDownloadStatus(done: 2, known: 0)
        #expect(DownloadState(status.rollup(trackCount: nil)) == .complete(undownloadable: 0))
        #expect(DownloadState(status.rollup(trackCount: 12)) == .partial(done: 2, total: 12))

        // An artist: the section's list gives every album a total.
        let statuses = ["9": AlbumDownloadStatus(artistKey: "A", done: 2, known: 2, pinned: true)]
        let albums = [
            PlexAlbum(ratingKey: "9", title: "", parentRatingKey: "A", parentTitle: nil, year: nil, thumb: nil, leafCount: 2),
            PlexAlbum(ratingKey: "8", title: "", parentRatingKey: "A", parentTitle: nil, year: nil, thumb: nil, leafCount: 5),
            PlexAlbum(ratingKey: "7", title: "", parentRatingKey: "B", parentTitle: nil, year: nil, thumb: nil, leafCount: 5),
        ]
        var inventory = DownloadInventory()
        inventory.statuses = statuses
        #expect(inventory.state(ofArtist: "A", albums: albums) == .partial(done: 2, total: 7))
        #expect(inventory.state(ofArtist: "A", albums: []) == .complete(undownloadable: 0), "before the list loads")
        #expect(inventory.state(ofArtist: "B", albums: albums) == .none)
    }
}
