import Foundation

/// One pick in a mix: the favorites, a playlist, an artist or an album.
/// The title (and for an album its artist) ride along with the key so a
/// saved mix can be drawn on any device it syncs to before the library
/// has loaded, and the thumb so it can show the art; identity is the
/// kind and key alone, so a renamed playlist is still the same pick.
public enum MixPick: Hashable, Sendable {
    case favorites
    case playlist(ratingKey: String, title: String, thumb: String?)
    case artist(ratingKey: String, title: String, thumb: String?)
    case album(ratingKey: String, title: String, artistKey: String?, artist: String?, thumb: String?)

    public var kind: MixPickKind {
        switch self {
        case .favorites: .favorites
        case .playlist: .playlist
        case .artist: .artist
        case .album: .album
        }
    }

    /// The server's key; nil for favorites, which is a query.
    public var ratingKey: String? {
        switch self {
        case .favorites: nil
        case .playlist(let key, _, _), .artist(let key, _, _), .album(let key, _, _, _, _): key
        }
    }

    /// "Favorites", or the item's own name.
    public var title: String {
        switch self {
        case .favorites: "Favorites"
        case .playlist(_, let title, _), .artist(_, let title, _), .album(_, let title, _, _, _): title
        }
    }

    public var thumb: String? {
        switch self {
        case .favorites: nil
        case .playlist(_, _, let thumb), .artist(_, _, let thumb), .album(_, _, _, _, let thumb): thumb
        }
    }

    /// `artist:123`, `favorites:`. What the mix builder keeps its
    /// selection as, and what decides equality.
    public var id: String {
        "\(kind.rawValue):\(ratingKey ?? "")"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(playlist: PlexPlaylist) {
        self = .playlist(ratingKey: playlist.ratingKey, title: playlist.title, thumb: playlist.composite)
    }

    public init(artist: PlexArtist) {
        self = .artist(ratingKey: artist.ratingKey, title: artist.title, thumb: artist.thumb)
    }

    public init(album: PlexAlbum) {
        self = .album(ratingKey: album.ratingKey, title: album.title, artistKey: album.parentRatingKey,
                      artist: album.parentTitle, thumb: album.thumb)
    }

    /// Whether the active listeners hide the pick outright: an artist or
    /// an album by its own veto or a wider one. Favorites and playlists
    /// are mixed bags, decided by their tracks instead.
    public func isHidden(by hidden: VetoSet) -> Bool {
        switch self {
        case .favorites, .playlist: false
        case .artist(let key, _, _): hidden.artists.contains(key)
        case .album(let key, _, let artistKey, _, _):
            hidden.albums.contains(key) || artistKey.map { hidden.artists.contains($0) } ?? false
        }
    }
}

public enum MixPickKind: String, Codable, Sendable, CaseIterable {
    case favorites, playlist, artist, album

    /// "Playlist", for the caption that tells the kinds apart.
    public var label: String {
        switch self {
        case .favorites: "Favorites"
        case .playlist: "Playlist"
        case .artist: "Artist"
        case .album: "Album"
        }
    }
}

extension MixPick: Codable {
    enum CodingKeys: String, CodingKey { case kind, key, title, artistKey, artist, thumb }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(MixPickKind.self, forKey: .kind)
        let key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        let thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        self = switch kind {
        case .favorites: .favorites
        case .playlist: .playlist(ratingKey: key, title: title, thumb: thumb)
        case .artist: .artist(ratingKey: key, title: title, thumb: thumb)
        case .album: .album(ratingKey: key, title: title,
                            artistKey: try c.decodeIfPresent(String.self, forKey: .artistKey),
                            artist: try c.decodeIfPresent(String.self, forKey: .artist), thumb: thumb)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(ratingKey, forKey: .key)
        if kind != .favorites { try c.encode(title, forKey: .title) }
        try c.encodeIfPresent(thumb, forKey: .thumb)
        if case .album(_, _, let artistKey, let artist, _) = self {
            try c.encodeIfPresent(artistKey, forKey: .artistKey)
            try c.encodeIfPresent(artist, forKey: .artist)
        }
    }
}

/// How a mix lays its tracks in the queue.
public enum PlayStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// In order: the picks in the order they were made, each as the
    /// server lists it (a playlist's order, an album front to back, an
    /// artist's albums oldest first, favorites newest heart first).
    case play
    /// The spread shuffle by artist then album, like every shuffle here.
    case shuffle
    /// Whole albums front to back, the album order shuffled.
    case mixAlbums

    public var id: String { rawValue }

    /// The two styles offered for a set of picks: one album, playlist or
    /// the favorites has an order worth keeping, so Play and Shuffle;
    /// anything else is a mix, so Mix Albums and Shuffle.
    public static func cases(for picks: [MixPick]) -> [PlayStyle] {
        picks.count == 1 && picks[0].kind != .artist ? [.play, .shuffle] : [.mixAlbums, .shuffle]
    }

    /// The verb the card's title starts with.
    public var verb: String {
        switch self {
        case .play: "Play"
        case .shuffle: "Shuffle"
        case .mixAlbums: "Mix Albums"
        }
    }

    /// Orders tracks the way the style plays them.
    public func ordered(_ tracks: [PlexTrack]) -> [PlexTrack] {
        switch self {
        case .play: tracks
        case .shuffle: tracks.spreadShuffled()
        case .mixAlbums: tracks.albumShuffled()
        }
    }
}

/// A mix kept for later: what the mix builder had picked and how it was
/// to play, under a name, as one of the play buttons at the top of the
/// Music screen. No picks is the whole library, as in the builder. Kept
/// in the same iCloud key-value store as the listeners, so every device
/// on the Apple ID shows the same row.
public struct SavedMix: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var picks: [MixPick]
    public var style: PlayStyle

    public init(id: UUID = UUID(), name: String, picks: [MixPick], style: PlayStyle) {
        self.id = id
        self.name = name
        self.picks = picks
        self.style = style
    }

    /// "Shuffle Favorites", "Play Road Trip", "Mix Albums Bon Jovi".
    public var title: String {
        "\(style.verb) \(name)"
    }

    /// A name for the picks when none is given: the one pick's title,
    /// two joined, "Bon Jovi & 2 more" past that, "Everything" for none.
    public static func suggestedName(for picks: [MixPick]) -> String {
        switch picks.count {
        case 0: "Everything"
        case 1: picks[0].title
        case 2: "\(picks[0].title) & \(picks[1].title)"
        default: "\(picks[0].title) & \(picks.count - 1) more"
        }
    }

    /// The id of the mix a first launch starts with, Shuffle Favorites.
    /// Fixed so two devices set up before iCloud syncs agree on it; after
    /// that it is a mix like any other, renamed or removed the same way.
    public static let starterID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    public static let starter = SavedMix(id: starterID, name: "Favorites", picks: [.favorites], style: .shuffle)

    enum CodingKeys: String, CodingKey { case id, name, picks, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A style this build doesn't know (added later) plays plain.
        let style = try c.decodeIfPresent(String.self, forKey: .style).flatMap(PlayStyle.init) ?? .play
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            picks: try c.decodeIfPresent([MixPick].self, forKey: .picks) ?? [],
            style: style
        )
    }
}
