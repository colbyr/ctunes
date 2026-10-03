import Foundation
import Testing
@testable import PlexKit

@Suite("Track cache")
struct TrackCacheTests {
    private func source(id: Int, stamp: Int = 1746246593, size: Int = 1024, server: String = "M") -> TrackSource {
        CacheTestSupport.source(id: id, stamp: stamp, size: size, server: server)
    }

    /// The cache and its cache root (not the pinned root).
    private func makeCache(
        limit: Int = 2 << 30,
        body: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response = { _ in
            .init(body: Data(count: 1024))
        }
    ) throws -> (TrackCache, URL, CacheTestSupport.Counter) {
        let (cache, _, counter) = try CacheTestSupport.makeCache(limit: limit, body: body)
        return (cache, cache.directory, counter)
    }

    // MARK: - Keys

    @Test("derives the cache key and the file name per quality from the part path")
    func cacheKey() {
        let flac = PlexPart(key: "/library/parts/1017/1746246593/file.flac")
        #expect(flac.cacheKey == "1017-1746246593")
        #expect(flac.fileExtension == "flac")
        #expect(flac.cacheFileName(quality: .original) == "1017-1746246593.flac")
        #expect(flac.cacheFileName(quality: .kbps128) == "1017-1746246593-q128.mp3")
        #expect(flac.cachePath(server: "M") == "M/1017-1746246593")
        #expect(flac.cachePath(server: "M", quality: .kbps320) == "M/1017-1746246593-q320.mp3")
        #expect(PlexPart(key: "/library/parts/1017/1746246593/track 01.mp3").cacheFileName(quality: .original) == "1017-1746246593.mp3")
    }

    @Test("a file name reads back as its key and quality")
    func variants() {
        #expect(TrackCache.variant(ofFileName: "1017-1746246593.flac") == ("1017-1746246593", .original))
        #expect(TrackCache.variant(ofFileName: "1017-1746246593.mp3") == ("1017-1746246593", .original))
        #expect(TrackCache.variant(ofFileName: "1017-1746246593-q192.mp3") == ("1017-1746246593", .kbps192))
        #expect(StreamQuality.original.satisfies(.kbps128))
        #expect(StreamQuality.kbps192.satisfies(.kbps128))
        #expect(!StreamQuality.kbps128.satisfies(.kbps192))
        #expect(!StreamQuality.kbps320.satisfies(.original))
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

    @Test("the server's Content-Length outranks a stale part size")
    func contentLengthWins() async throws {
        // Plex reports the size at scan time; a file retagged since is
        // served at its new length. That is a complete download, not a
        // truncated one.
        let (cache, _, _) = try makeCache { _ in
            .init(body: Data(count: 900), headers: ["Content-Length": "900"])
        }
        let track = source(id: 1017, size: 1024)
        try await cache.download(track)
        #expect(cache.localURL(for: track) != nil)

        let (short, _, _) = try makeCache { _ in
            .init(body: Data(count: 10), headers: ["Content-Length": "900"])
        }
        await #expect(throws: TrackCache.Failure.sizeMismatch(expected: 900, actual: 10)) {
            try await short.download(track)
        }
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

    /// The library moved to another address mid-fetch: the fetch on the
    /// old one is cancelled rather than joined, and the new one lands.
    @Test("retain cancels a fetch stuck on the old address when the window moves")
    func retainFollowsAddress() async throws {
        let (cache, _, counter) = try makeCache { request in
            if request.url?.host() == "old.plex.direct" { return .hang }
            return .init(body: Data(count: 1024))
        }
        let file = CacheTestSupport.part(id: 1)
        let old = TrackSource(server: "M", part: file,
                              request: URLRequest(url: URL(string: "https://old.plex.direct:32400" + file.key)!))
        let new = CacheTestSupport.source(part: file)
        await cache.retain(window: [old])
        try await Task.sleep(for: .milliseconds(50))
        await cache.retain(window: [new])
        try await cache.drain()
        #expect(cache.localURL(for: new) != nil)
        #expect(counter.count == 2)
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

    // MARK: - Transcoded copies

    @Test("a transcoded source goes through the download queue and lands under its own name")
    func transcodedFetch() async throws {
        let queue = CacheTestSupport.QueueServer(polls: 2)
        let (cache, directory, _) = try makeCache(body: queue.handler)
        await cache.queue.setPollInterval(.milliseconds(5))
        let source = CacheTestSupport.transcoded(id: 1017, quality: .kbps128)

        let url = try await cache.download(source)

        #expect(url == directory.appending(path: "M/1017-1746246593-q128.mp3"))
        #expect(cache.localURL(for: source) == url)
        #expect(cache.localURL(server: "M", part: source.part, quality: .kbps128) == url)
        #expect(cache.localURL(server: "M", part: source.part, quality: .kbps192) == nil, "not as good as asked")
        #expect(cache.localURL(server: "M", part: source.part, quality: .original) == nil)
        #expect(cache.localURL(server: "M", part: source.part) == url, "anything offline")
        #expect(TrackCache.quality(ofFile: url) == .kbps128)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 700)
        // Polled until available, fetched the media, deleted the item.
        try await Task.sleep(for: .milliseconds(50))
        let requests = queue.requests
        #expect(requests.first == "POST /downloadQueue")
        #expect(requests.contains("POST /downloadQueue/2/add"))
        #expect(requests.filter { $0 == "GET /downloadQueue/2/items/6" }.count == 3)
        #expect(requests.contains("GET /downloadQueue/2/item/6/media"))
        #expect(requests.last == "DELETE /downloadQueue/2/items/6")
        // The add asks for MP3 under the cap, strictly encoded.
        let add = try #require(queue.urls.first { $0.contains("/add?") })
        #expect(add.contains("keys=%2Flibrary%2Fmetadata%2F1017"))
        #expect(add.contains("musicBitrate=128"))
        #expect(add.contains("directPlay=0"))
        #expect(add.contains("protocol=http"))
        #expect(add.contains("audioCodec%3Dmp3%29"))
        #expect(!add.contains("X-Plex-Token"), "the token rides in a header")
    }

    @Test("a queue the server doesn't have fails the window copy and gives a pin the original")
    func queueUnavailable() async throws {
        let (cache, _, counter) = try makeCache { request in
            if request.url?.path.hasPrefix("/downloadQueue") == true { return .init(status: 404, body: Data()) }
            return .init(body: Data(count: 1024))
        }
        let source = CacheTestSupport.transcoded(id: 1017, quality: .kbps128)

        await #expect(throws: TrackCache.Failure.queueUnavailable) {
            try await cache.download(source)
        }
        #expect(cache.localURL(server: "M", part: source.part) == nil)
        #expect(!counter.requests.contains(source.part.key), "the window never downloads an original behind a cap")

        await cache.retryFailed()
        await cache.pin([source])
        try await cache.drain()
        let url = try #require(cache.localURL(server: "M", part: source.part))
        #expect(url.lastPathComponent == "1017-1746246593.flac")
        #expect(url.path.hasPrefix(cache.pinnedDirectory.path))
        #expect(counter.requests.filter { $0 == source.part.key }.count == 1)
        // The refusal is remembered: the next pin asks for the original at once.
        let other = CacheTestSupport.transcoded(id: 1018, quality: .kbps128)
        let before = counter.requests.filter { $0.hasPrefix("/downloadQueue") }.count
        await cache.pin([other])
        try await cache.drain()
        #expect(cache.localURL(server: "M", part: other.part) != nil)
        #expect(counter.requests.filter { $0.hasPrefix("/downloadQueue") }.count == before)
    }

    @Test("a better copy replaces a lesser one in the same root")
    func variantReplaces() async throws {
        let queue = CacheTestSupport.QueueServer(polls: 0)
        let (cache, directory, _) = try makeCache(body: queue.handler)
        let low = CacheTestSupport.transcoded(id: 1017, quality: .kbps128)
        let high = CacheTestSupport.source(part: low.part)

        try await cache.download(low)
        #expect(cache.localURL(for: high) == nil)
        try await cache.download(high)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "M").path)
        #expect(names == ["1017-1746246593.flac"])
        #expect(cache.localURL(for: low)?.lastPathComponent == "1017-1746246593.flac", "the original is as good as 128")
        #expect(await cache.usage() == 1024)
    }

    @Test("a pin takes a cached copy only when it is as good as asked")
    func pinTakesGoodEnoughCopy() async throws {
        let queue = CacheTestSupport.QueueServer(polls: 0)
        let (cache, _, counter) = try makeCache(body: queue.handler)
        let low = CacheTestSupport.transcoded(id: 1017, quality: .kbps128)
        try await cache.download(low)

        // Pinned at original: the 128 copy isn't good enough, so it fetches.
        await cache.pin([low.original])
        try await cache.drain()
        #expect(cache.isPinned(server: "M", part: low.part))
        #expect(cache.localURL(server: "M", part: low.part)?.lastPathComponent == "1017-1746246593.flac")
        #expect(counter.requests.contains(low.part.key))

        // Pinned at 128 with the original cached: renamed, not fetched.
        let other = CacheTestSupport.source(id: 1018)
        try await cache.download(other)
        let fetches = counter.count
        await cache.pin([CacheTestSupport.transcoded(id: 1018, quality: .kbps128)])
        try await cache.drain()
        #expect(cache.isPinned(server: "M", part: other.part))
        #expect(counter.count == fetches)
    }

    @Test("a closed gate parks the pump and puts the in-flight fetch back")
    func gate() async throws {
        let (cache, _, counter) = try makeCache { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return .init(body: Data(count: 1024))
        }
        let a = source(id: 1), b = source(id: 2)
        await cache.setDownloadsAllowed(false)
        await cache.retain(window: [a, b])
        try await Task.sleep(for: .milliseconds(50))
        #expect(counter.count == 0)
        #expect(await !cache.isPumping)

        await cache.setDownloadsAllowed(true)
        try await Task.sleep(for: .milliseconds(30))
        await cache.setDownloadsAllowed(false)
        try await cache.drain()
        #expect(cache.localURL(for: a) == nil, "cancelled mid-fetch")
        #expect(await cache.failedPaths().isEmpty, "a cancellation is not a failure")

        await cache.setDownloadsAllowed(true)
        try await cache.drain()
        #expect(cache.localURL(for: a) != nil)
        #expect(cache.localURL(for: b) != nil)
    }

    @Test("retain refetches at a higher quality and cancels a fetch at the old one")
    func retainFollowsQuality() async throws {
        let queue = CacheTestSupport.QueueServer(polls: 0)
        let (cache, _, _) = try makeCache(body: queue.handler)
        let part = CacheTestSupport.part(id: 1017)
        let low = CacheTestSupport.transcoded(id: 1017, quality: .kbps128)
        let mid = CacheTestSupport.transcoded(id: 1017, quality: .kbps192)
        let high = CacheTestSupport.source(part: part)

        await cache.retain(window: [low])
        try await cache.drain()
        #expect(cache.localURL(server: "M", part: part, quality: .kbps192) == nil)
        await cache.retain(window: [mid])
        try await cache.drain()
        #expect(cache.localURL(server: "M", part: part, quality: .kbps192)?.lastPathComponent == "1017-1746246593-q192.mp3")
        #expect(cache.localURL(server: "M", part: part, quality: .kbps128)?.lastPathComponent == "1017-1746246593-q192.mp3")
        await cache.retain(window: [high])
        try await cache.drain()
        #expect(cache.localURL(for: high) != nil)
        #expect(await cache.usage() == 1024, "one copy per part in the root")
    }
}
