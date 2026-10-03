import Foundation
import os

/// Keeps whole track files on disk so a played track is served locally next
/// time and the next few queue entries are downloaded before they're reached.
///
/// Two roots, one pump. Files live at `directory/<server>/<file name>`, which
/// the app points at Caches, so iOS may purge it between launches and LRU
/// trims it to `limit`. Pinned files live at `pinnedDirectory/<server>/<file name>`
/// under Application Support: uncapped, never evicted, excluded from backup.
/// Nothing here is treated as truth except the file system, which
/// `localURL(server:part:quality:)` checks every time.
///
/// A part has one key (`PlexPart.cacheKey`, the id and stamp) and may be on
/// disk as the original (`<key>.flac`) or as a copy the server's download
/// queue transcoded (`<key>-q128.mp3`). The window, the pins and the
/// failure memo are keyed by the part; the quality is a property of the
/// fetch. A root holds one copy of a part: a fetch that lands replaces any
/// other. A pinned file plays whatever its quality, since a pin is an ask
/// to play from disk; a cached one only when it is as good as the quality
/// asked for, so a 128 kbps copy left from a cellular listen doesn't stand
/// in for the original at home.
///
/// Downloads run one at a time: the current track is streaming through
/// AVPlayer's own connection pool at the same time and must not be starved.
/// The window (what the player wants next) is always served before the pin
/// queue, so the next track is never stuck behind an album download. A
/// transcoded fetch is add → poll → fetch → delete on the download queue,
/// which never touches the live transcoder a stream is using. The pump
/// also has a gate (`setDownloadsAllowed`) the app closes on cellular when
/// the user has said no: nothing is fetched, what was in flight is put back
/// at the head of its queue, and the gate opening starts it again.
public actor TrackCache {
    public nonisolated let directory: URL
    public nonisolated let pinnedDirectory: URL
    private var limit: Int
    private let session: URLSession
    let queue: DownloadQueueClient

    private var inFlight: [String: Task<URL, Error>] = [:]
    /// The source each in-flight fetch is for, so a window handed over
    /// after the library moved (Wi-Fi to cellular) or the quality changed
    /// cancels a fetch for the old one rather than joining it.
    private var inFlightSources: [String: TrackSource] = [:]
    /// What the player wants on disk right now, keyed by `cachePath`.
    /// Eviction never touches these.
    private var window: Set<String> = []
    private var pending: [TrackSource] = []
    /// What the user asked to keep, by `cachePath`, with the quality the
    /// pin asked for. A fetch that satisfies it lands in the pinned root
    /// and is never cancelled by `retain`.
    private var pinned: [String: StreamQuality] = [:]
    private var pinQueue: [TrackSource] = []
    private var pump: Task<Void, Never>?
    /// Keys that failed recently, so a dead server or a full disk isn't
    /// retried on every cursor move.
    private var failed: [String: Date] = [:]
    var retryAfter: TimeInterval = 5 * 60
    /// Servers whose download queue refused us, and when: an older server
    /// with no endpoint, or a token the feature is gated for. A pin falls
    /// back to the original file and the window skips the track, until
    /// `queueRetryAfter` has passed.
    private var queueUnavailable: [String: Date] = [:]
    var queueRetryAfter: TimeInterval = 60 * 60
    /// The gate: whether the pump may run at all.
    private var downloadsAllowed = true
    /// Whether a fetch may use cellular data. The gate above is what stops
    /// the pump; this rides on each request as the backstop, so a path that
    /// turns cellular under a fetch fails it rather than finishing it.
    private var allowsCellular = true
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "TrackCache")

    /// Download starts and ends, so a status view can refresh from disk
    /// without polling. Buffered, so a consumer that isn't listening yet
    /// loses nothing.
    public nonisolated let events: AsyncStream<Event>
    private nonisolated let eventContinuation: AsyncStream<Event>.Continuation

    public enum Event: Sendable, Equatable {
        case started(String), finished(String), failed(String)
    }

    public init(directory: URL, pinnedDirectory: URL, limit: Int = 2 << 30, session: URLSession) {
        self.directory = directory
        self.pinnedDirectory = pinnedDirectory
        self.limit = limit
        self.session = session
        self.queue = DownloadQueueClient(session: session)
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    public enum Failure: Error, Equatable {
        case notCacheable
        case badResponse(status: Int)
        case sizeMismatch(expected: Int, actual: Int)
        /// The server's download queue is not available for a transcoded
        /// copy, and this fetch is not a pin's, so there is no fallback.
        case queueUnavailable
    }

    /// One file in the pinned root.
    public struct FileInfo: Sendable, Equatable {
        public let size: Int
        public let quality: StreamQuality
    }

    // MARK: - Lookup

    /// Synchronous so the player can pick an item URL without hopping actors:
    /// a hop would let the cursor move under it. Pinned root first, at any
    /// quality; then the cache root at the source's quality or better.
    public nonisolated func localURL(for source: TrackSource) -> URL? {
        localURL(server: source.server, part: source.part, quality: source.quality)
    }

    /// A file for the part. The pinned root at any quality first: a pin is
    /// an ask to play from disk. Then the cache root at `quality` or
    /// better; nil `quality` takes anything, which is what offline wants.
    public nonisolated func localURL(server: String, part: PlexPart, quality: StreamQuality? = nil) -> URL? {
        guard let path = part.cachePath(server: server) else { return nil }
        return pinnedURL(path, part: part) ?? cachedURL(path, part: part, atLeast: quality)
    }

    /// Whether a file for the part is in the pinned root, on disk right now.
    public nonisolated func isPinned(server: String, part: PlexPart) -> Bool {
        guard let path = part.cachePath(server: server) else { return false }
        return pinnedURL(path, part: part) != nil
    }

    /// The quality of a file one of the lookups returned, from its name.
    public nonisolated static func quality(ofFile url: URL) -> StreamQuality {
        variant(ofFileName: url.lastPathComponent).quality
    }

    private nonisolated func cachedURL(_ path: String, part: PlexPart, atLeast quality: StreamQuality?) -> URL? {
        existing(in: directory, path: path, part: part, atLeast: quality)
    }

    private nonisolated func pinnedURL(_ path: String, part: PlexPart) -> URL? {
        existing(in: pinnedDirectory, path: path, part: part, atLeast: nil)
    }

    /// The best copy in `root` that satisfies `quality`. Four stats at most.
    private nonisolated func existing(in root: URL, path: String, part: PlexPart, atLeast quality: StreamQuality?) -> URL? {
        let parent = root.appending(path: path).deletingLastPathComponent()
        for candidate in StreamQuality.allCases where quality.map(candidate.satisfies) ?? true {
            guard let name = part.cacheFileName(quality: candidate) else { return nil }
            let url = parent.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Bumps the modification date so LRU sees the play.
    public func touch(_ source: TrackSource) {
        touch(server: source.server, part: source.part)
    }

    public func touch(server: String, part: PlexPart) {
        guard let url = localURL(server: server, part: part) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }

    // MARK: - Downloading

    /// The set worth having on disk, in priority order. Downloads outside it
    /// are cancelled unless pinned, and so is a window fetch whose source
    /// changed (address or quality); missing entries are fetched one at a
    /// time, ahead of anything in the pin queue.
    public func retain(window sources: [TrackSource]) {
        let wanted = Dictionary(sources.compactMap { source in source.cachePath.map { ($0, source) } },
                                uniquingKeysWith: { first, _ in first })
        window = Set(wanted.keys)
        for (path, task) in inFlight where pinned[path] == nil {
            let left = !window.contains(path)
            let changed = wanted[path].map { $0 != inFlightSources[path] } ?? false
            if left || changed { task.cancel() }
        }
        pending = sources.filter { source in
            guard let path = source.cachePath else { return false }
            return localURL(for: source) == nil && !recentlyFailed(path)
        }
        startPump()
    }

    /// Keeps these on disk until `unpin`. Appends to the pin queue behind
    /// the window; a file already in the cache root that is as good as the
    /// pin asks for is renamed into the pinned root, never fetched twice.
    public func pin(_ sources: [TrackSource]) {
        for source in sources {
            guard let path = source.cachePath else { continue }
            pinned[path] = source.quality
            if pinnedURL(path, part: source.part) != nil { continue }
            if let cached = cachedURL(path, part: source.part, atLeast: source.quality) {
                let destination = pinnedDirectory.appending(path: path).deletingLastPathComponent()
                    .appending(path: cached.lastPathComponent)
                if (try? move(cached, to: destination)) != nil {
                    eventContinuation.yield(.finished(path))
                    continue
                }
            }
            // An in-flight fetch that is as good as the pin wants lands in
            // the pinned root on its own; one for a lesser copy, or on an
            // address the library has left, makes way for the pin's.
            if let flying = inFlightSources[path] {
                if flying.request.url == source.request.url, flying.quality.satisfies(source.quality) { continue }
                inFlight[path]?.cancel()
            }
            if let queued = pinQueue.firstIndex(where: { $0.cachePath == path }) {
                pinQueue[queued] = source
                continue
            }
            guard !recentlyFailed(path) else { continue }
            pinQueue.append(source)
        }
        startPump()
    }

    /// Drops the pins: cancels a fetch that only the pin wanted, or renames
    /// the file back into the cache root, modification date untouched, so
    /// LRU reaches it in its turn.
    public func unpin(_ paths: [String]) {
        for path in paths {
            pinned.removeValue(forKey: path)
            pinQueue.removeAll { $0.cachePath == path }
            if !window.contains(path) { inFlight[path]?.cancel() }
            for url in files(in: pinnedDirectory, matching: path) {
                let destination = directory.appending(path: path).deletingLastPathComponent()
                    .appending(path: url.lastPathComponent)
                try? move(url, to: destination)
            }
        }
        evictIfNeeded()
    }

    private func startPump() {
        guard pump == nil, downloadsAllowed else { return }
        pump = Task {
            while downloadsAllowed, let next = nextToFetch() {
                _ = try? await download(next)
                // The gate closed under it: back to the head of its queue
                // for when the gate opens, not lost until the next retain.
                if !downloadsAllowed, let path = next.cachePath,
                   localURL(for: next) == nil, !recentlyFailed(path) {
                    if pinned[path] != nil { pinQueue.insert(next, at: 0) } else { pending.insert(next, at: 0) }
                }
            }
            pump = nil
        }
    }

    /// Window first, then pins.
    private func nextToFetch() -> TrackSource? {
        if !pending.isEmpty { return pending.removeFirst() }
        if !pinQueue.isEmpty { return pinQueue.removeFirst() }
        return nil
    }

    /// Whether the pump may run. The app closes the gate on cellular when
    /// downloads there are off: in-flight fetches are cancelled and put
    /// back, and nothing starts until it opens.
    public func setDownloadsAllowed(_ allowed: Bool) {
        guard allowed != downloadsAllowed else { return }
        downloadsAllowed = allowed
        if allowed {
            startPump()
        } else {
            for task in inFlight.values { task.cancel() }
        }
    }

    /// Whether fetches may use cellular data at all; see `allowsCellular`.
    public func setAllowsCellular(_ allowed: Bool) {
        allowsCellular = allowed
    }

    /// Fetches the file unless it's cached or already on its way, joining the
    /// in-flight download in that case. A caller giving up doesn't cancel
    /// the fetch; only `retain`, `unpin`, `clear` and the gate do.
    @discardableResult
    public func download(_ source: TrackSource) async throws -> URL {
        guard let path = source.cachePath else { throw Failure.notCacheable }
        if let hit = localURL(for: source) { return hit }
        if let task = inFlight[path] { return try await task.value }

        let task = Task { try await fetch(source, path: path) }
        inFlight[path] = task
        inFlightSources[path] = source
        defer {
            inFlight[path] = nil
            inFlightSources[path] = nil
        }
        eventContinuation.yield(.started(path))
        do {
            let url = try await task.value
            eventContinuation.yield(.finished(path))
            return url
        } catch {
            // A cancellation or a path with no network is nothing to hold
            // against the track; anything else waits out the backoff.
            let code = (error as? URLError)?.code
            let transient = error is CancellationError || code == .cancelled || code == .notConnectedToInternet
            if !transient {
                failed[path] = Date()
                logger.error("download failed \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            eventContinuation.yield(.failed(path))
            throw error
        }
    }

    private func fetch(_ source: TrackSource, path: String) async throws -> URL {
        var attempts = 0
        while true {
            attempts += 1
            do {
                return try await fetchOnce(source, path: path)
            } catch let error as URLError where error.code == .networkConnectionLost && attempts == 1 {
                // The server dropped an idle keep-alive connection; a fresh
                // request opens a fresh one. Same failure the player retries.
                continue
            } catch let error as DownloadQueueClient.Failure where source.quality != .original {
                // The queue won't give a transcoded copy. A pin is an ask
                // for the track offline, so it gets the original; the
                // window's copy is an optimisation and is skipped, since
                // an original behind a bandwidth setting defeats it.
                if case .unavailable = error { queueUnavailable[source.server] = Date() }
                logger.error("download queue \(String(describing: error), privacy: .public) for \(path, privacy: .public)")
                guard pinned[path] != nil else { throw Failure.queueUnavailable }
                logger.notice("pin falls back to the original for \(path, privacy: .public)")
                return try await fetchOnce(source.original, path: path)
            }
        }
    }

    private func fetchOnce(_ source: TrackSource, path: String) async throws -> URL {
        guard let filePath = source.filePath else { throw Failure.notCacheable }
        var request = source.request
        var cleanup: URLRequest?
        if let job = source.queueJob {
            if let since = queueUnavailable[source.server], Date().timeIntervalSince(since) < queueRetryAfter {
                throw DownloadQueueClient.Failure.unavailable(status: 0)
            }
            let prepared = try await queue.prepare(job)
            request = prepared.media
            cleanup = prepared.delete
        }
        defer {
            // The item stays listed on the server until deleted. Detached,
            // so a cancellation here still sends it.
            if let cleanup {
                let session = session
                Task.detached { _ = try? await session.data(for: cleanup) }
            }
        }
        request.allowsCellularAccess = allowsCellular
        let (temp, response) = try await session.download(for: request)
        // The temp file has no lifetime guarantee: nothing below suspends
        // before it's moved.
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temp) }
        try Task.checkCancellation()

        // No Range header was sent, so anything but a whole-file 200 is an
        // error page.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.badResponse(status: status) }

        // A truncated body is caught against what the server said it was
        // sending. The part's `size` is only a fallback, for the original
        // alone: it is the size at scan time, and a file retagged since is
        // served at its new length while the metadata still says the old
        // one. A transcoded copy has nothing but the response to go on.
        let actual = (try? manager.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? -1
        let expected = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : source.expectedSize
        if let expected, expected != actual {
            throw Failure.sizeMismatch(expected: expected, actual: actual)
        }
        if actual <= 0 { throw Failure.sizeMismatch(expected: 1, actual: actual) }

        // Decided now, not when the fetch started: a track pinned while its
        // window fetch was in flight lands in the pinned root, if the copy
        // is as good as the pin asked for.
        let root = pinned[path].map(source.quality.satisfies) == true ? pinnedDirectory : directory
        let destination = root.appending(path: filePath)
        try move(temp, to: destination)
        #if os(iOS)
        // Explicit, so a future stricter entitlement can't leave a lock-screen
        // skip staring at an unreadable file.
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        #endif
        if root == directory { evictIfNeeded() }
        return destination
    }

    /// A rename within the volume: the file either exists whole at the
    /// destination or not at all. Creates the parent, marks the pinned
    /// root as not for backup the first time it appears, and removes any
    /// other copy of the part in that root, so a root holds one.
    private func move(_ from: URL, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        if destination.path.hasPrefix(pinnedDirectory.path) {
            var root = pinnedDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
        let key = Self.variant(ofFileName: destination.lastPathComponent).key
        for sibling in Self.siblings(of: destination.lastPathComponent, key: key, in: parent) where sibling != destination {
            try? manager.removeItem(at: sibling)
        }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: from, to: destination)
    }

    /// Whether the sequential download pump is running.
    var isPumping: Bool { pump != nil }

    /// Bytes the cache root is trimmed to. Lowering it evicts now, least
    /// recently played first, never the window; the pinned root is untouched.
    public func setLimit(_ bytes: Int) {
        limit = bytes
        evictIfNeeded()
    }

    /// Cache paths whose last fetch failed and are still inside the backoff,
    /// so a status view can tell a stalled download from a slow one.
    public func failedPaths() -> Set<String> {
        Set(failed.keys.filter(recentlyFailed))
    }

    /// Forgets the backoff, so the next `pin` or `retain` tries again now.
    /// The download queue's refusal is forgotten with it.
    public func retryFailed() {
        failed = [:]
        queueUnavailable = [:]
    }

    private func recentlyFailed(_ path: String) -> Bool {
        guard let at = failed[path] else { return false }
        return Date().timeIntervalSince(at) < retryAfter
    }

    // MARK: - Space

    public func evict(_ source: TrackSource) {
        evict(server: source.server, part: source.part)
    }

    /// Removes the part's files from both roots. A pinned file that won't
    /// play is a bad file; the pin stays wanted and the next `pin` fetches
    /// it again.
    public func evict(server: String, part: PlexPart) {
        guard let path = part.cachePath(server: server) else { return }
        for url in files(in: pinnedDirectory, matching: path) + files(in: directory, matching: path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes the one file an item was built from, when it won't play.
    public func evict(fileAt url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Bytes in the cache root across every server.
    public func usage() -> Int {
        files(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Bytes in the pinned root.
    public func pinnedUsage() -> Int {
        files(in: pinnedDirectory).reduce(0) { $0 + $1.size }
    }

    /// Every file in the pinned root with its size and quality, by cache
    /// path: one walk, so an inventory over hundreds of tracks stats
    /// nothing per track.
    public func pinnedFiles() -> [String: FileInfo] {
        Dictionary(
            files(in: pinnedDirectory).map { ($0.path, FileInfo(size: $0.size, quality: $0.quality)) },
            uniquingKeysWith: { first, second in first.quality.satisfies(second.quality) ? first : second }
        )
    }

    /// Removes everything in the cache root, cancelling its downloads first.
    /// Pins are untouched. `keeping` is the current track: unlinking a file
    /// under a playing item is not something to find out about on the lock
    /// screen.
    public func clear(keeping: TrackSource? = nil) {
        clear(keepingPath: keeping?.cachePath)
    }

    public func clear(keepingPath: String?) {
        pending = []
        for (path, task) in inFlight where pinned[path] == nil { task.cancel() }
        failed = [:]
        for file in files(in: directory) where file.path != keepingPath {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Forgets every pin and removes the pinned root, cancelling pin fetches.
    public func clearPinned() {
        pinQueue = []
        for (path, task) in inFlight where pinned[path] != nil && !window.contains(path) {
            task.cancel()
        }
        pinned = [:]
        try? FileManager.default.removeItem(at: pinnedDirectory)
    }

    /// Least recently played first, down to the limit, never the window.
    /// Only the cache root: the pinned root has no limit.
    private func evictIfNeeded() {
        var total = 0
        var candidates: [CachedFile] = []
        for file in files(in: directory) {
            total += file.size
            candidates.append(file)
        }
        guard total > limit else { return }
        candidates.sort { $0.modified < $1.modified }
        for file in candidates where total > limit {
            if window.contains(file.path) { continue }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: - Files

    private struct CachedFile {
        let url: URL
        /// `server/key`, the form `window` uses, whatever the copy's quality.
        let path: String
        let quality: StreamQuality
        let size: Int
        let modified: Date
    }

    /// `1017-1746246593-q128.mp3` → key `1017-1746246593`, 128 kbps;
    /// `1017-1746246593.flac` → the same key, original.
    nonisolated static func variant(ofFileName name: String) -> (key: String, quality: StreamQuality) {
        let stem = (name as NSString).deletingPathExtension
        if (name as NSString).pathExtension == "mp3", let dash = stem.range(of: "-q", options: .backwards),
           let bitrate = Int(stem[dash.upperBound...]), let quality = StreamQuality(bitrate: bitrate) {
            return (String(stem[..<dash.lowerBound]), quality)
        }
        return (stem, .original)
    }

    /// Every copy of the part in `parent`, by its key.
    private nonisolated static func siblings(of fileName: String, key: String, in parent: URL) -> [URL] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: parent.path) else { return [] }
        return names.filter { Self.variant(ofFileName: $0).key == key }.map { parent.appending(path: $0) }
    }

    /// Every copy of the part at `path` (`server/key`) in `root`.
    private nonisolated func files(in root: URL, matching path: String) -> [URL] {
        let full = root.appending(path: path)
        return Self.siblings(of: full.lastPathComponent, key: full.lastPathComponent, in: full.deletingLastPathComponent())
    }

    private func files(in root: URL) -> [CachedFile] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [CachedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : full
            let variant = Self.variant(ofFileName: url.lastPathComponent)
            let path = (relative as NSString).deletingLastPathComponent
            result.append(CachedFile(
                url: url,
                path: path.isEmpty ? variant.key : "\(path)/\(variant.key)",
                quality: variant.quality,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }
}
