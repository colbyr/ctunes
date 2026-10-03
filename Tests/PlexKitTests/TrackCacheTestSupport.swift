import Foundation
import Testing
@testable import PlexKit

/// Shared between the cache and offline store suites.
enum CacheTestSupport {
    static let base = URL(string: "https://example.plex.direct:32400")!

    /// A fresh directory per test; swift-testing runs suites in parallel.
    static func makeDirectory(_ prefix: String = "CacheTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func part(id: Int, stamp: Int = 1746246593, size: Int = 1024) -> PlexPart {
        PlexPart(key: "/library/parts/\(id)/\(stamp)/file.flac", container: "flac", size: size)
    }

    static func source(id: Int, stamp: Int = 1746246593, size: Int = 1024, server: String = "M") -> TrackSource {
        source(part: part(id: id, stamp: stamp, size: size), server: server)
    }

    static func source(part: PlexPart, server: String = "M") -> TrackSource {
        TrackSource(server: server, part: part, request: URLRequest(url: base.appending(path: part.key)))
    }

    /// A source for a transcoded copy, through a download queue at `base`.
    static func transcoded(id: Int, quality: StreamQuality, server: String = "M") -> TrackSource {
        let part = part(id: id)
        var queue = URLRequest(url: base.appending(path: "/downloadQueue"))
        queue.httpMethod = "POST"
        queue.setValue("TOKEN", forHTTPHeaderField: "X-Plex-Token")
        return TrackSource(
            server: server, part: part,
            request: URLRequest(url: base.appending(path: part.key)),
            quality: quality,
            queueJob: DownloadQueueJob(request: queue, ratingKey: String(id), bitrate: quality.bitrate ?? 0)
        )
    }

    /// Answers the download queue the way the server was measured to: one
    /// queue (id 2), every add is item 6, which is `processing` for `polls`
    /// polls and then `available`, and the media is 700 bytes with a
    /// `Content-Length`. Anything else is a 1024-byte part file.
    final class QueueServer: @unchecked Sendable {
        private var polled = 0
        private var log: [(String, String)] = []
        private let lock = NSLock()
        private let polls: Int

        init(polls: Int) { self.polls = polls }

        /// "METHOD /path", in order.
        var requests: [String] { lock.withLock { log.map { "\($0.0) \(URL(string: $0.1)?.path ?? "")" } } }
        var urls: [String] { lock.withLock { log.map(\.1) } }

        var handler: @Sendable (URLRequest) -> MockURLProtocol.Response {
            { [self] request in
                let method = request.httpMethod ?? "GET"
                let path = request.url?.path ?? ""
                lock.withLock { log.append((method, request.url?.absoluteString ?? "")) }
                switch (method, path) {
                case ("POST", "/downloadQueue"):
                    return .json(#"{"MediaContainer":{"DownloadQueue":[{"id":2,"owner":1,"itemCount":0,"status":"done"}]}}"#)
                case ("GET", "/downloadQueue/2/items"):
                    return .json(#"{"MediaContainer":{}}"#)
                case ("POST", "/downloadQueue/2/add"):
                    return .json(#"{"MediaContainer":{"AddedQueueItems":[{"key":"/library/metadata/1017","id":6}]}}"#)
                case ("GET", "/downloadQueue/2/items/6"):
                    let n = lock.withLock { polled += 1; return polled }
                    if n <= polls {
                        return .json(#"{"MediaContainer":{"DownloadQueueItem":[{"id":6,"queueId":2,"status":"processing","transcode":{"progress":\#(n * 40),"context":"static"}}]}}"#)
                    }
                    return .json(#"{"MediaContainer":{"DownloadQueueItem":[{"id":6,"queueId":2,"status":"available"}]}}"#)
                case ("GET", "/downloadQueue/2/item/6/media"):
                    return .init(body: Data(count: 700), headers: ["Content-Length": "700", "Content-Type": "application/octet-stream"])
                case ("DELETE", "/downloadQueue/2/items/6"):
                    return .init(status: 204, body: Data())
                default:
                    return .init(body: Data(count: 1024))
                }
            }
        }
    }

    /// A track whose part is `part(id:)`, sized to the mock's 1024-byte body.
    static func track(
        id: Int, album: String, artist: String, title: String? = nil, key: String? = nil
    ) -> PlexTrack {
        let part = key.map { PlexPart(key: $0, container: "flac", size: 1024) } ?? part(id: id)
        let json = """
        {"ratingKey":"\(id)","title":"\(title ?? "Track \(id)")","index":\(id),"duration":1000,
         "parentRatingKey":"\(album)","grandparentRatingKey":"\(artist)",
         "Media":[{"container":"flac","Part":[{"key":"\(part.key)","container":"flac","size":\(part.size ?? 0)}]}]}
        """
        return try! JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    /// A cache whose server answers every part with 1024 zero bytes, the
    /// size `source(id:)` declares, and counts the requests.
    static func makeCache(
        limit: Int = 2 << 30,
        body: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response = { _ in
            .init(body: Data(count: 1024))
        }
    ) throws -> (TrackCache, URL, Counter) {
        let counter = Counter()
        let root = try makeDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "Caches"), withIntermediateDirectories: true)
        let cache = TrackCache(
            directory: root.appending(path: "Caches"),
            pinnedDirectory: root.appending(path: "Pinned"),
            limit: limit,
            session: MockURLProtocol.session { request in
                counter.increment(request)
                return body(request)
            }
        )
        return (cache, root, counter)
    }

    final class Counter: @unchecked Sendable {
        private var value = 0
        private var log: [String] = []
        private let lock = NSLock()
        func increment(_ request: URLRequest? = nil) {
            lock.withLock {
                value += 1
                if let path = request?.url?.path { log.append(path) }
            }
        }
        var count: Int { lock.withLock { value } }
        /// Request paths in the order they arrived.
        var requests: [String] { lock.withLock { log } }
    }
}

extension TrackCache {
    /// Waits for the pump to finish, for tests.
    func drain() async throws {
        while await isPumping {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func setRetryAfter(_ seconds: TimeInterval) {
        retryAfter = seconds
    }
}
