import Foundation

/// Keeps whole track files on disk so a played track is served locally next
/// time and the next few queue entries are downloaded before they're reached.
///
/// Files live at `directory/<server>/<cacheKey>`. The app points `directory`
/// at Caches, so iOS may purge it between launches; nothing here is treated as
/// truth except the file system, which `localURL(for:)` checks every time.
/// Downloads run one at a time: the current track is streaming through
/// AVPlayer's own connection pool at the same time and must not be starved.
public actor TrackCache {
    public nonisolated let directory: URL
    private let limit: Int
    private let session: URLSession

    private var inFlight: [String: Task<URL, Error>] = [:]
    /// What the player wants on disk right now, keyed by `cachePath`.
    /// Eviction never touches these.
    private var window: Set<String> = []
    private var pending: [TrackSource] = []
    private var pump: Task<Void, Never>?
    /// Keys that failed recently, so a dead server or a full disk isn't
    /// retried on every cursor move.
    private var failed: [String: Date] = [:]
    private let retryAfter: TimeInterval = 5 * 60

    public init(directory: URL, limit: Int = 2 << 30, session: URLSession) {
        self.directory = directory
        self.limit = limit
        self.session = session
    }

    public enum Failure: Error, Equatable {
        case notCacheable
        case badResponse(status: Int)
        case sizeMismatch(expected: Int, actual: Int)
    }

    // MARK: - Lookup

    /// Synchronous so the player can pick an item URL without hopping actors:
    /// a hop would let the cursor move under it.
    public nonisolated func localURL(for source: TrackSource) -> URL? {
        guard let path = source.cachePath else { return nil }
        let url = directory.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Bumps the modification date so LRU sees the play.
    public func touch(_ source: TrackSource) {
        guard let url = localURL(for: source) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }

    // MARK: - Downloading

    /// The set worth having on disk, in priority order. Downloads outside it
    /// are cancelled; missing entries are fetched one at a time.
    public func retain(window sources: [TrackSource]) {
        let wanted = sources.compactMap(\.cachePath)
        window = Set(wanted)
        for (path, task) in inFlight where !window.contains(path) {
            task.cancel()
        }
        pending = sources.filter { source in
            guard let path = source.cachePath else { return false }
            return localURL(for: source) == nil && !recentlyFailed(path)
        }
        guard pump == nil else { return }
        pump = Task {
            while !pending.isEmpty {
                let next = pending.removeFirst()
                _ = try? await download(next)
            }
            pump = nil
        }
    }

    /// Fetches the file unless it's cached or already on its way, joining the
    /// in-flight download in that case. A caller giving up doesn't cancel
    /// the fetch; only `retain` and `clear` do.
    @discardableResult
    public func download(_ source: TrackSource) async throws -> URL {
        guard let path = source.cachePath else { throw Failure.notCacheable }
        if let hit = localURL(for: source) { return hit }
        if let task = inFlight[path] { return try await task.value }

        let task = Task { try await fetch(source, path: path) }
        inFlight[path] = task
        defer { inFlight[path] = nil }
        do {
            return try await task.value
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                failed[path] = Date()
            }
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

        let destination = directory.appending(path: path)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? manager.removeItem(at: destination)
        // Same volume, so a rename: the file either exists whole or not at all.
        try manager.moveItem(at: temp, to: destination)
        #if os(iOS)
        // Explicit, so a future stricter entitlement can't leave a lock-screen
        // skip staring at an unreadable file.
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        #endif
        evictIfNeeded()
        return destination
    }

    /// Whether the sequential download pump is running.
    var isPumping: Bool { pump != nil }

    private func recentlyFailed(_ path: String) -> Bool {
        guard let at = failed[path] else { return false }
        return Date().timeIntervalSince(at) < retryAfter
    }

    // MARK: - Space

    public func evict(_ source: TrackSource) {
        guard let url = localURL(for: source) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Bytes on disk across every server.
    public func usage() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    /// Removes everything, cancelling downloads first. `keeping` is the
    /// current track: unlinking a file under a playing item is not something
    /// to find out about on the lock screen.
    public func clear(keeping: TrackSource? = nil) {
        pump?.cancel()
        pump = nil
        pending = []
        for task in inFlight.values { task.cancel() }
        failed = [:]
        let keep = keeping.flatMap(\.cachePath).map { directory.appending(path: $0).standardizedFileURL }
        for file in files() where file.url.standardizedFileURL != keep {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Least recently played first, down to the limit, never the window.
    private func evictIfNeeded() {
        var total = 0
        var candidates: [CachedFile] = []
        for file in files() {
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

    private func files() -> [CachedFile] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let root = directory.standardizedFileURL.path
        var result: [CachedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : full
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
