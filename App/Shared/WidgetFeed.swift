import Foundation

/// What the home screen widgets draw, written by the app into the App
/// Group container and read by the widget extension. A widget is another
/// process in another bundle: it sees none of the app's defaults, its
/// Application Support folder, the artwork cache or the keychain, and it
/// must never discover a server or talk to Plex itself. So the browse
/// root, which already settles which shortcut cards to show for the
/// people listening, writes them here as they are drawn (title, line
/// under it, what the art is, its tint) with a small JPEG of each cover
/// beside the file, and asks WidgetKit to reload. The plan is
/// `notes/widgets.md`.
struct WidgetFeed: Codable, Sendable, Equatable {
    struct Card: Codable, Sendable, Hashable, Identifiable {
        /// What stands for the mix: the heart disc, a round portrait, a
        /// cover, a playlist composite, or the mix builder's glyph for
        /// several picks or none.
        enum Art: String, Codable, Sendable {
            case favorites, artist, album, playlist, mix
        }

        /// The style glyph's color, as the card on the Music screen.
        enum Accent: String, Codable, Sendable {
            case heart, playlist, amber, mix
        }

        let id: UUID
        /// "Shuffle Favorites", "Play Road Trip".
        let title: String
        /// The line under it: "32 tracks for you & Laura".
        let subtitle: String?
        let art: Art
        /// The file under `thumbs/`, when the art is a picture that has
        /// been saved.
        let thumb: String?
        let tint: ArtworkTint?
        /// The style's SF Symbol: play, shuffle or the album stack.
        let symbol: String
        let accent: Accent

        /// The saved JPEG, when there is one.
        var thumbURL: URL? {
            thumb.flatMap { WidgetFeed.thumbs?.appending(path: $0) }
        }

        /// What a tap outside the play button opens: the mix on the
        /// Music screen, through the app's URL scheme.
        var openURL: URL {
            URL(string: "ctunes://mix/\(id.uuidString)")!
        }

        /// What the gallery and a widget with no feed yet show.
        static let placeholder = Card(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "Shuffle Favorites", subtitle: "Everything you've hearted",
            art: .favorites, thumb: nil, tint: nil, symbol: "shuffle", accent: .heart
        )
    }

    var cards: [Card]
    var written: Date

    static let group = "group.com.colbyr.ctunes"

    /// The widget kinds, for `WidgetCenter` reloads and the bundle.
    enum Kind {
        static let shortcut = "Shortcut"
        static let shortcuts = "Shortcuts"
    }

    /// Nil when the build is signed without the App Group entitlement,
    /// in which case the widgets show the placeholder.
    nonisolated static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    nonisolated static var file: URL? { container?.appending(path: "widget.json") }
    nonisolated static var thumbs: URL? { container?.appending(path: "thumbs") }

    nonisolated static func read() -> WidgetFeed? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetFeed.self, from: data)
    }

    nonisolated func write() throws {
        guard let file = Self.file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// `/library/metadata/649/thumb/1746246600` as a file name, its
    /// punctuation dashed the way the offline store and the tint cache
    /// key it, so the same cover at any size is one file.
    nonisolated static func thumbName(for thumb: String) -> String {
        thumb.drop { $0 == "/" }.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + ".jpg"
    }
}
