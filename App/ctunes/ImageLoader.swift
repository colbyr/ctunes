import SwiftUI

/// Fetches and caches artwork so views share one copy per URL.
///
/// `AsyncImage` cancels its request when the view disappears and then sits in
/// `.failure` until the view is rebuilt, which is why list art went blank at
/// random while scrolling. Here a load is a shared task keyed by URL: a view
/// giving up on it (cancelled `.task`) doesn't cancel the request, the result
/// still lands in the cache, and the next appearance is a memory hit. A failed
/// load is retried on the next request.
///
/// Plex thumb paths carry a version stamp, so a URL is immutable and the disk
/// cache is used without revalidation.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private nonisolated let session: URLSession

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 50 << 20,
            diskCapacity: 500 << 20,
            directory: caches?.appendingPathComponent("Artwork")
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.totalCostLimit = 100 << 20
        tints = Self.loadTints()
    }

    /// The cached image, if the URL has already been loaded.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Loads the image, joining an in-flight request for the same URL.
    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let task = inFlight[url] { return await task.value }

        let session = session
        let task = Task<UIImage?, Never> {
            // Decoded off the main actor so a burst of list art doesn't stall
            // scrolling.
            await Task.detached(priority: .userInitiated) {
                // Offline art is a file the offline store saved: read it
                // directly rather than through the URL cache.
                let data = url.isFileURL
                    ? try? Data(contentsOf: url)
                    : try? await session.data(from: url).0
                guard let data, let image = UIImage(data: data) else { return nil }
                return image.preparingForDisplay() ?? image
            }.value
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
            // Every cover that lands, a grid tile included, gets its tint
            // worked out now, so the album page or Now Playing it leads to
            // opens on its color rather than fading in a beat later.
            let key = Self.tintKey(url)
            if tints[key] == nil { Task { _ = await computeTint(image, key: key, priority: .utility) } }
        }
        return image
    }

    /// Starts loading without waiting, so a later view finds it in cache.
    func prewarm(_ url: URL?) {
        guard let url, cached(url) == nil, inFlight[url] == nil else { return }
        Task { _ = await image(for: url) }
    }

    /// The art's dominant color, computed once per cover and kept on disk,
    /// so a sleeve seen on any earlier launch opens on its color at once.
    /// Keyed by the cover, not the URL: the same art at 400, 600 or 900px,
    /// or from the offline store, downsamples to the same handful of pixels.
    private var tints: [String: ArtworkTint]
    private var tintsInFlight: [String: Task<ArtworkTint?, Never>] = [:]
    private var tintSave: Task<Void, Never>?

    /// The tint if it is already known, for a first frame without a fade.
    func cachedTint(for url: URL) -> ArtworkTint? {
        tints[Self.tintKey(url)]
    }

    func tint(for url: URL) async -> ArtworkTint? {
        let key = Self.tintKey(url)
        if let hit = tints[key] { return hit }
        if let task = tintsInFlight[key] { return await task.value }
        guard let image = await image(for: url) else { return nil }
        if let hit = tints[key] { return hit }
        return await computeTint(image, key: key, priority: .userInitiated)
    }

    private func computeTint(_ image: UIImage, key: String, priority: TaskPriority) async -> ArtworkTint? {
        if let task = tintsInFlight[key] { return await task.value }
        // Off the main actor: 1024 pixels is quick, but not free during a
        // sheet's presentation animation.
        let task = Task.detached(priority: priority) { image.dominantTint() }
        tintsInFlight[key] = task
        let tint = await task.value
        tintsInFlight[key] = nil
        if let tint, tints[key] == nil {
            tints[key] = tint
            scheduleTintSave()
        }
        return tint
    }

    /// `/library/metadata/649/thumb/1746246600` however it is fetched:
    /// the `url` query of a transcode request, or the offline store's
    /// file name, which is the same path with its punctuation dashed.
    nonisolated static func tintKey(_ url: URL) -> String {
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        let thumb = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value
        guard let thumb else { return url.absoluteString }
        return thumb.drop { $0 == "/" }.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    // MARK: - Tints on disk

    private static let tintsFile: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appending(path: "ctunes/ArtworkTints.json")

    /// One JSON object of `key: [r, g, b]`; a few dozen bytes a cover.
    private static func loadTints() -> [String: ArtworkTint] {
        guard let file = tintsFile, let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else { return [:] }
        return raw.compactMapValues { channels in
            guard channels.count == 3 else { return nil }
            return ArtworkTint(red: channels[0], green: channels[1], blue: channels[2])
        }
    }

    /// Coalesces a grid's worth of new tints into one write, off the main
    /// actor.
    private func scheduleTintSave() {
        tintSave?.cancel()
        tintSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let file = Self.tintsFile else { return }
            let raw = tints.mapValues { [$0.red, $0.green, $0.blue] }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(raw) else { return }
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }.value
        }
    }
}
