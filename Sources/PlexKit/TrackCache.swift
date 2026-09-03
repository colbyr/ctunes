import Foundation

/// Keeps whole track files on disk so a played track is served locally next
/// time and the next few queue entries are downloaded before they're reached.
///
/// Two roots, one pump. Files live at `directory/<server>/<cacheKey>`, which
/// the app points at Caches, so iOS may purge it between launches and LRU
/// trims it to `limit`. Pinned files live at `pinnedDirectory/<server>/<cacheKey>`
/// under Application Support: uncapped, never evicted, excluded from backup.
/// Nothing here is treated as truth except the file system, which
/// `localURL(for:)` checks every time.
///
/// Downloads run one at a time: the current track is streaming through
/// AVPlayer's own connection pool at the same time and must not be starved.
/// The window (what the player wants next) is always served before the pin
/// queue, so the next track is never stuck behind an album download.
public actor TrackCache {
    public nonisolated let directory: URL
    public nonisolated let pinnedDirectory: URL
    private let limit: Int
    private let session: URLSession

    private var inFlight: [String: Task<URL, Error>] = [:]
    /// What the player wants on disk right now, keyed by `cachePath`.
    /// Eviction never touches these.
    private var window: Set<String> = []
    private var pending: [TrackSource] = []
    /// What the user asked to keep, keyed by `cachePath`. A fetch for one
    /// of these lands in the pinned root and is never cancelled by `retain`.
    private var pinned: Set<String> = []
    private var pinQueue: [TrackSource] = []
    private var pump: Task<Void, Never>?
    /// Keys that failed recently, so a dead server or a full disk isn't
    /// retried on every cursor move.
    private var failed: [String: Date] = [:]
    var retryAfter: TimeInterval = 5 * 60

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
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    public enum Failure: Error, Equatable {
        case notCacheable
        case badResponse(status: Int)
        case sizeMismatch(expected: Int, actual: Int)
    }

    // MARK: - Lookup

    /// Synchronous so the player can pick an item URL without hopping actors:
    /// a hop would let the cursor move under it. Pinned root first.
    public nonisolated func localURL(for source: TrackSource) -> URL? {
        localURL(server: source.server, part: source.part)
    }

    public nonisolated func localURL(server: String, part: PlexPart) -> URL? {
        guard let path = part.cachePath(server: server) else { return nil }
        return pinnedURL(path) ?? cachedURL(path)
    }

    /// Whether the file is in the pinned root, on disk right now.
    public nonisolated func isPinned(server: String, part: PlexPart) -> Bool {
        guard let path = part.cachePath(server: server) else { return false }
        return pinnedURL(path) != nil
    }

    private nonisolated func cachedURL(_ path: String) -> URL? {
        let url = directory.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func pinnedURL(_ path: String) -> URL? {
        let url = pinnedDirectory.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
    /// are cancelled unless pinned; missing entries are fetched one at a
    /// time, ahead of anything in the pin queue.
    public func retain(window sources: [TrackSource]) {
        let wanted = sources.compactMap(\.cachePath)
        window = Set(wanted)
        for (path, task) in inFlight where !window.contains(path) && !pinned.contains(path) {
            task.cancel()
        }
        pending = sources.filter { source in
            guard let path = source.cachePath else { return false }
            return localURL(for: source) == nil && !recentlyFailed(path)
        }
        startPump()
    }

    /// Keeps these on disk until `unpin`. Appends to the pin queue behind
    /// the window; a file already in the cache root is renamed into the
    /// pinned root, never fetched twice.
    public func pin(_ sources: [TrackSource]) {
        for source in sources {
            guard let path = source.cachePath else { continue }
            pinned.insert(path)
            if pinnedURL(path) != nil { continue }
            if let cached = cachedURL(path) {
                if (try? move(cached, to: pinnedDirectory.appending(path: path))) != nil {
                    eventContinuation.yield(.finished(path))
                    continue
                }
            }
            // An in-flight window fetch checks `pinned` when it lands, so it
            // needs no help; a queued one is filed again harmlessly.
            guard inFlight[path] == nil, !recentlyFailed(path),
                  !pinQueue.contains(where: { $0.cachePath == path })
            else { continue }
            pinQueue.append(source)
        }
        startPump()
    }

    /// Drops the pins: cancels a fetch that only the pin wanted, or renames
    /// the file back into the cache root, modification date untouched, so
    /// LRU reaches it in its turn.
    public func unpin(_ paths: [String]) {
        for path in paths {
            pinned.remove(path)
            pinQueue.removeAll { $0.cachePath == path }
            if !window.contains(path) { inFlight[path]?.cancel() }
            if let url = pinnedURL(path) {
                try? move(url, to: directory.appending(path: path))
            }
        }
        evictIfNeeded()
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task {
            while let next = nextToFetch() {
                _ = try? await download(next)
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

    /// Fetches the file unless it's cached or already on its way, joining the
    /// in-flight download in that case. A caller giving up doesn't cancel
    /// the fetch; only `retain`, `unpin` and `clear` do.
    @discardableResult
    public func download(_ source: TrackSource) async throws -> URL {
        guard let path = source.cachePath else { throw Failure.notCacheable }
        if let hit = localURL(for: source) { return hit }
        if let task = inFlight[path] { return try await task.value }

        let task = Task { try await fetch(source, path: path) }
        inFlight[path] = task
        defer { inFlight[path] = nil }
        eventContinuation.yield(.started(path))
        do {
            let url = try await task.value
            eventContinuation.yield(.finished(path))
            return url
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                failed[path] = Date()
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
            }
        }
    }

    private func fetchOnce(_ source: TrackSource, path: String) async throws -> URL {
        let (temp, response) = try await session.download(for: source.request)
        // The temp file has no lifetime guarantee: nothing below suspends
        // before it's moved.
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temp) }
        try Task.checkCancellation()

        // No Range header was sent, so anything but a whole-file 200 is an
        // error page.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.badResponse(status: status) }

        let actual = (try? manager.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? -1
        let expected = source.expectedSize
            ?? (response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil)
        if let expected, expected != actual {
            throw Failure.sizeMismatch(expected: expected, actual: actual)
        }

        // Decided now, not when the fetch started: a track pinned while its
        // window fetch was in flight lands in the pinned root.
        let root = pinned.contains(path) ? pinnedDirectory : directory
        let destination = root.appending(path: path)
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
    /// destination or not at all. Creates the parent, and marks the pinned
    /// root as not for backup the first time it appears.
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
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: from, to: destination)
    }

    /// Whether the sequential download pump is running.
    var isPumping: Bool { pump != nil }

    private func recentlyFailed(_ path: String) -> Bool {
        guard let at = failed[path] else { return false }
        return Date().timeIntervalSince(at) < retryAfter
    }

    // MARK: - Space

    public func evict(_ source: TrackSource) {
        evict(server: source.server, part: source.part)
    }

    /// Removes the file from whichever root holds it. A pinned file that
    /// won't play is a bad file; the pin stays wanted and the next
    /// `pin` fetches it again.
    public func evict(server: String, part: PlexPart) {
        guard let url = localURL(server: server, part: part) else { return }
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

    /// Removes everything in the cache root, cancelling its downloads first.
    /// Pins are untouched. `keeping` is the current track: unlinking a file
    /// under a playing item is not something to find out about on the lock
    /// screen.
    public func clear(keeping: TrackSource? = nil) {
        clear(keepingPath: keeping?.cachePath)
    }

    public func clear(keepingPath: String?) {
        pending = []
        for (path, task) in inFlight where !pinned.contains(path) { task.cancel() }
        failed = [:]
        let keep = keepingPath.map { directory.appending(path: $0).standardizedFileURL }
        for file in files(in: directory) where file.url.standardizedFileURL != keep {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Forgets every pin and removes the pinned root, cancelling pin fetches.
    public func clearPinned() {
        pinQueue = []
        for (path, task) in inFlight where pinned.contains(path) && !window.contains(path) {
            task.cancel()
        }
        pinned = []
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

    private struct CachedFile {
        let url: URL
        /// `server/key`, the form `window` uses.
        let path: String
        let size: Int
        let modified: Date
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
            result.append(CachedFile(
                url: url,
                path: relative,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }
}
