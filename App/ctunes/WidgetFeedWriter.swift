import os
import PlexKit
import SwiftUI
import WidgetKit

/// Writes the shortcut cards the Music screen shows into the App Group
/// for the widgets, with a small JPEG of each cover beside the feed and
/// its tint in it, then asks WidgetKit to redraw. Called from the browse
/// root as its cards settle, which is the one place the listener vetoes
/// and the playlist counts are already worked out. A reload asked for
/// while the app is in front costs nothing of the widgets' budget.
@MainActor
enum WidgetFeedWriter {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Widget")
    /// The last feed written this launch, so an unchanged root doesn't
    /// rewrite it on every count that lands.
    private static var written: [WidgetFeed.Card]?
    /// Covers at 200pt fill a 56pt disc on a 3x screen with room over.
    private static let thumbSide: CGFloat = 200

    static func publish(_ mixes: [(mix: SavedMix, subtitle: String?)], library: any LibrarySource) async {
        guard let thumbs = WidgetFeed.thumbs else { return }
        var cards: [WidgetFeed.Card] = []
        for (mix, subtitle) in mixes {
            if Task.isCancelled { return }
            let pick = mix.picks.count == 1 ? mix.picks[0] : nil
            var thumb: String?
            var tint: ArtworkTint?
            if let pick, let path = pick.thumb, let url = library.artworkURL(path) {
                let name = WidgetFeed.thumbName(for: path)
                if await save(url, as: thumbs.appending(path: name)) {
                    thumb = name
                    tint = await ImageLoader.shared.tint(for: url)
                }
            }
            cards.append(WidgetFeed.Card(
                id: mix.id, title: mix.title, subtitle: subtitle,
                art: pick.map(art) ?? .mix, thumb: thumb, tint: tint,
                symbol: mix.style.symbol, accent: accent(of: mix)
            ))
        }
        guard !Task.isCancelled, cards != written else { return }
        do {
            try WidgetFeed(cards: cards, written: .now).write()
        } catch {
            log.error("feed write failed: \(String(describing: error), privacy: .public)")
            return
        }
        written = cards
        prune(thumbs, keeping: Set(cards.compactMap(\.thumb)))
        WidgetCenter.shared.reloadAllTimelines()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CTUNES_DEV_WIDGET_FEED"] == "1" {
            let lines = cards.map { "\($0.title) [\($0.art.rawValue)\($0.thumb == nil ? "" : ", thumb")\($0.tint == nil ? "" : ", tint")] \($0.subtitle ?? "")" }
            log.info("feed written: \(lines.joined(separator: "; "), privacy: .public)")
        }
        #endif
    }

    /// The cover at `thumbSide`, written once; true when the file is
    /// there to draw.
    private static func save(_ url: URL, as file: URL) async -> Bool {
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let image = await ImageLoader.shared.image(for: url) else { return false }
        let side = thumbSide
        return await Task.detached(priority: .utility) {
            // 2x, not the screen's scale: 400px fills a 56pt disc on a 3x
            // screen with room over, at a quarter of the bytes.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            let scaled = renderer.image { _ in
                // Fill the square the way the card does, cropping a
                // portrait's edges rather than letterboxing it.
                let scale = max(side / image.size.width, side / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }
            guard let data = scaled.jpegData(compressionQuality: 0.8) else { return false }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    private static func prune(_ thumbs: URL, keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: thumbs.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: thumbs.appending(path: file))
        }
    }

    private static func art(of pick: MixPick) -> WidgetFeed.Card.Art {
        switch pick.kind {
        case .favorites: .favorites
        case .artist: .artist
        case .album: .album
        case .playlist: .playlist
        }
    }

    private static func accent(of mix: SavedMix) -> WidgetFeed.Card.Accent {
        guard mix.picks.count == 1 else { return .mix }
        switch mix.picks[0].kind {
        case .favorites: return .heart
        case .playlist: return .playlist
        case .artist, .album: return .amber
        }
    }
}
