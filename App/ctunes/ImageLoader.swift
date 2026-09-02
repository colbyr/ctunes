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
                guard let (data, _) = try? await session.data(from: url),
                      let image = UIImage(data: data) else { return nil }
                return image.preparingForDisplay() ?? image
            }.value
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    /// Starts loading without waiting, so a later view finds it in cache.
    func prewarm(_ url: URL?) {
        guard let url, cached(url) == nil, inFlight[url] == nil else { return }
        Task { _ = await image(for: url) }
    }
}
