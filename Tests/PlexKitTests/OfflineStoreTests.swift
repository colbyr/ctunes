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
        await store.pinAlbum(album, tracks: tracks, server: Self.server, section: "1", art: nil, sources: sources)
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

    @Test("nothing on disk carries a token or an absolute URL")
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
            #expect(!text.contains("https://"), "\(file)")
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
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
        #expect(await store.tracks(inAlbum: "9", server: Self.server) == nil)
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

        var statuses = await store.statuses(server: Self.server)
        #expect(statuses["9"] == .complete)
        #expect(statuses["8"] == .partial(undownloadable: 1))

        await cache.evict(server: Self.server, part: whole[0].part!)
        statuses = await store.statuses(server: Self.server)
        #expect(statuses["9"] == .pending(done: 1, total: 2))
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
        #expect(await store.statuses(server: Self.server)["9"] == .pending(done: 2, total: 3))

        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 3, "within the backoff")

        await cache.setRetryAfter(0)
        await store.resume(server: Self.server, sources: sources)
        try await cache.drain()
        #expect(counter.count == 4)
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
        #expect(await relaunched.statuses(server: Self.server)["9"] == .complete)
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
            art: Support.base.appending(path: "/photo/:/transcode"), sources: sources
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
}
