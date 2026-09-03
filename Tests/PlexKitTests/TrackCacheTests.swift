import Foundation
import Testing
@testable import PlexKit

@Suite("Track cache")
struct TrackCacheTests {
    private static let base = URL(string: "https://example.plex.direct:32400")!

    /// A fresh directory per test; swift-testing runs suites in parallel.
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TrackCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(id: Int, stamp: Int = 1746246593, size: Int = 1024, server: String = "M") -> TrackSource {
        let key = "/library/parts/\(id)/\(stamp)/file.flac"
        return TrackSource(
            server: server,
            part: PlexPart(key: key, container: "flac", size: size),
            request: URLRequest(url: Self.base.appending(path: key))
        )
    }

    /// A cache whose server answers every part with 1024 zero bytes, the
    /// size `source(id:)` declares, and counts the requests.
    private func makeCache(
        limit: Int = 2 << 30,
        body: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response = { _ in
            .init(body: Data(count: 1024))
        }
    ) throws -> (TrackCache, URL, Counter) {
        let counter = Counter()
        let directory = try makeDirectory()
        let cache = TrackCache(
            directory: directory,
            limit: limit,
            session: MockURLProtocol.session { request in
                counter.increment()
                return body(request)
            }
        )
        return (cache, directory, counter)
    }

    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    // MARK: - Keys

    @Test("derives the cache key from the part path")
    func cacheKey() {
        #expect(PlexPart(key: "/library/parts/1017/1746246593/file.flac").cacheKey == "1017-1746246593.flac")
        #expect(PlexPart(key: "/library/parts/1017/1746246593/track 01.mp3").cacheKey == "1017-1746246593.mp3")
    }

    @Test("refuses keys that aren't a plain part file", arguments: [
        "/library/parts/1017/file.flac",
        "/library/parts/1017/1746246593/../file.flac",
        "/library/parts/abc/1746246593/file.flac",
        "/library/parts/1017/1746246593/file",
        "/library/parts/1017/1746246593/file.fl/ac",
        "/music/:/transcode/universal/start.m3u8?path=1017",
        "",
    ])
    func rejectsOtherKeys(key: String) {
        #expect(PlexPart(key: key).cacheKey == nil)
    }

    // MARK: - Downloading

    @Test("a miss downloads the file and the next lookup hits")
    func missThenHit() async throws {
        let (cache, directory, counter) = try makeCache()
        let track = source(id: 1017)
        #expect(cache.localURL(for: track) == nil)

        let url = try await cache.download(track)

        #expect(url == directory.appending(path: "M/1017-1746246593.flac"))
        #expect(cache.localURL(for: track) == url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 1024)
        #expect(counter.count == 1)
        try await cache.download(track)
        #expect(counter.count == 1)
    }

    @Test("concurrent downloads of one part share a request")
    func joinsInFlight() async throws {
        let (cache, _, counter) = try makeCache { request in
            Thread.sleep(forTimeInterval: 0.05)
            return .init(body: Data(count: 1024))
        }
        let track = source(id: 1017)
        async let first = cache.download(track)
        async let second = cache.download(track)
        _ = try await (first, second)
        #expect(counter.count == 1)
    }

    @Test("a short body is discarded")
    func sizeMismatch() async throws {
        let (cache, directory, _) = try makeCache { _ in .init(body: Data(count: 10)) }
        let track = source(id: 1017)
        await #expect(throws: TrackCache.Failure.sizeMismatch(expected: 1024, actual: 10)) {
            try await cache.download(track)
        }
        #expect(cache.localURL(for: track) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("an error page is discarded")
    func badStatus() async throws {
        let (cache, _, _) = try makeCache { _ in .init(status: 503, body: Data("<html>".utf8)) }
        let track = source(id: 1017)
        await #expect(throws: TrackCache.Failure.badResponse(status: 503)) {
            try await cache.download(track)
        }
        #expect(cache.localURL(for: track) == nil)
    }

    @Test("a failed part isn't retried by the next retain")
    func failureMemo() async throws {
        let (cache, _, counter) = try makeCache { _ in .init(status: 500, body: Data()) }
        let track = source(id: 1017)
        await cache.retain(window: [track])
        try await cache.drain()
        #expect(counter.count == 1)
        await cache.retain(window: [track])
        try await cache.drain()
        #expect(counter.count == 1)
    }

    // MARK: - Window

    @Test("retain downloads the window in order")
    func retainDownloads() async throws {
        let (cache, _, _) = try makeCache()
        let tracks = [source(id: 1), source(id: 2), source(id: 3)]
        await cache.retain(window: tracks)
        try await cache.drain()
        for track in tracks {
            #expect(cache.localURL(for: track) != nil)
        }
    }

    @Test("retain cancels a download that left the window")
    func retainCancels() async throws {
        let (cache, _, _) = try makeCache { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .init(body: Data(count: 1024))
        }
        let dropped = source(id: 1)
        let kept = source(id: 2)
        await cache.retain(window: [dropped])
        try await Task.sleep(for: .milliseconds(50))
        await cache.retain(window: [kept])
        try await cache.drain()
        #expect(cache.localURL(for: dropped) == nil)
        #expect(cache.localURL(for: kept) != nil)
    }

    // MARK: - Space

    @Test("evicts least recently played first, never the window")
    func eviction() async throws {
        // Room for two files.
        let (cache, _, _) = try makeCache(limit: 2 * 1024 + 512)
        let old = source(id: 1)
        let pinned = source(id: 2)
        let new = source(id: 3)

        try await cache.download(old)
        try await cache.download(pinned)
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: cache.localURL(for: old)!.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: past.addingTimeInterval(-3600)], ofItemAtPath: cache.localURL(for: pinned)!.path
        )

        await cache.retain(window: [pinned, new])
        try await cache.drain()

        #expect(cache.localURL(for: new) != nil)
        #expect(cache.localURL(for: pinned) != nil, "oldest, but in the window")
        #expect(cache.localURL(for: old) == nil)
        #expect(await cache.usage() == 2 * 1024)
    }

    @Test("touch makes a file recently played")
    func touch() async throws {
        let (cache, _, _) = try makeCache(limit: 2 * 1024 + 512)
        let a = source(id: 1)
        let b = source(id: 2)
        try await cache.download(a)
        try await cache.download(b)
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.localURL(for: a)!.path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.localURL(for: b)!.path)
        await cache.touch(a)

        try await cache.download(source(id: 3))

        #expect(cache.localURL(for: a) != nil)
        #expect(cache.localURL(for: b) == nil)
    }

    @Test("clear removes everything but the track being played")
    func clear() async throws {
        let (cache, _, _) = try makeCache()
        let playing = source(id: 1)
        let other = source(id: 2, server: "N")
        try await cache.download(playing)
        try await cache.download(other)
        #expect(await cache.usage() == 2048)

        await cache.clear(keeping: playing)

        #expect(cache.localURL(for: playing) != nil)
        #expect(cache.localURL(for: other) == nil)
        #expect(await cache.usage() == 1024)
        await cache.clear()
        #expect(await cache.usage() == 0)
    }
}

extension TrackCache {
    /// Waits for the pump to finish, for tests.
    func drain() async throws {
        while await isPumping {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
