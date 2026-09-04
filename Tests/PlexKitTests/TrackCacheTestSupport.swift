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
