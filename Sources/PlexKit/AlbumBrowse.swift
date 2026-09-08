import Foundation

/// The browse root's arrangements. Each is a fixed sort plus grouping, so
/// the two never have to be reconciled in the menu. Raw values are
/// persisted, so keep them stable.
public enum AlbumView: String, CaseIterable, Sendable, Codable {
    /// What's on rotation first, flat: recent plays weigh more than old
    /// ones, per track so a long album doesn't win by length. The default.
    /// The raw value predates the scoring and is persisted, so it stays.
    case mostPlayed
    /// Newest additions first, flat.
    case recentlyAdded
    /// Sectioned by artist A–Z, each artist's albums newest release first.
    case artist
    /// Sectioned by how long ago an album was last played, never-played
    /// first, the least recently played at the top of each section.
    case backCatalog

    public var title: String {
        switch self {
        case .mostPlayed: "On Rotation"
        case .recentlyAdded: "Recently Added"
        case .artist: "Artists"
        case .backCatalog: "Back Catalog"
        }
    }

    var sort: AlbumSort {
        switch self {
        case .mostPlayed: .rotation
        case .recentlyAdded: .addedAt
        case .artist: .releaseDate
        case .backCatalog: .lastPlayedAscending
        }
    }

    var grouping: AlbumGrouping {
        switch self {
        case .recentlyAdded, .mostPlayed: .none
        case .artist: .artist
        case .backCatalog: .lastPlayed
        }
    }

    /// The view's order alone, for the mix pools' flat search results.
    public func sorted(_ albums: [PlexAlbum], rotation: Rotation = .none) -> [PlexAlbum] {
        sort.sorted(albums, rotation: rotation)
    }

    /// The same view applied to a flat artist list, for the artist mix
    /// pool. An artist has no release date, so the Artist view reads as
    /// name order, which is what its sections do for albums anyway.
    public func sorted(_ artists: [PlexArtist], rotation: Rotation = .none) -> [PlexArtist] {
        sort.sorted(artists, rotation: rotation)
    }
}

/// How much each album and artist is being played lately, from the play
/// history. Every play is worth `0.5 ^ (age / halfLife)`, so ten plays this
/// week outrank thirty spread over a year; an album's sum is divided by the
/// square root of its track count, so a long album doesn't win by length
/// but a single doesn't win by brevity either. Dividing by the count
/// itself put every one-track single above whole albums played daily. An
/// artist's score is the sum over their albums.
public struct Rotation: Sendable, Equatable {
    /// Score by album rating key. Albums never played are absent.
    public let albums: [String: Double]
    /// Score by artist rating key.
    public let artists: [String: Double]

    /// No history: the sort falls back to the server's play counts.
    public static let none = Rotation(albums: [:], artists: [:])

    /// A play from two months ago is worth half of one today. At 90 days,
    /// ten plays this week only tied thirty spread over a year; at 60 they
    /// score 9.7 to 7.0.
    public static let halfLife: TimeInterval = 60 * 86_400
    /// How far back to fetch. Older plays would weigh under 2%.
    public static let window: TimeInterval = 365 * 86_400

    public var isEmpty: Bool { albums.isEmpty }

    init(albums: [String: Double], artists: [String: Double]) {
        self.albums = albums
        self.artists = artists
    }

    /// Plays of albums no longer in `albums` are dropped: they can't be
    /// browsed, and without the album there's no track count to divide by.
    public init(
        history: [PlayHistoryEntry],
        albums: [PlexAlbum],
        now: Date = .now,
        halfLife: TimeInterval = Rotation.halfLife
    ) {
        var plays: [String: Double] = [:]
        for entry in history {
            guard let key = entry.albumRatingKey else { continue }
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(entry.viewedAt)))
            plays[key, default: 0] += pow(0.5, max(age, 0) / halfLife)
        }
        var albumScores: [String: Double] = [:]
        var artistScores: [String: Double] = [:]
        for album in albums {
            guard let sum = plays[album.ratingKey] else { continue }
            let score = sum / Double(max(album.leafCount ?? 1, 1)).squareRoot()
            albumScores[album.ratingKey] = score
            artistScores[album.artistKey, default: 0] += score
        }
        self.albums = albumScores
        self.artists = artistScores
    }
}

/// The orderings behind `AlbumView`. Every key sorts descending except
/// `lastPlayedAscending`, whose missing values go first: an album never
/// played is the oldest thing in the back catalog.
enum AlbumSort: Sendable {
    case addedAt, rotation, releaseDate, lastPlayedAscending

    /// Stable ordering: albums missing the key sort to the bottom (top for
    /// the ascending sort), ties fall back to title so the order doesn't
    /// shift between loads.
    func sorted(_ albums: [PlexAlbum], rotation: Rotation = .none) -> [PlexAlbum] {
        sorted(albums, key: { key($0, rotation: rotation) }, title: \.title)
    }

    func sorted(_ artists: [PlexArtist], rotation: Rotation = .none) -> [PlexArtist] {
        sorted(artists, key: { key($0, rotation: rotation) }, title: \.title)
    }

    private var ascending: Bool { self == .lastPlayedAscending }

    private func sorted<T>(_ items: [T], key: (T) -> Double?, title: (T) -> String) -> [T] {
        items.sorted { lhs, rhs in
            switch (key(lhs), key(rhs)) {
            case let (l?, r?) where l != r: return ascending ? l < r : l > r
            case (.some, nil): return !ascending
            case (nil, .some): return ascending
            default: return title(lhs).localizedCaseInsensitiveCompare(title(rhs)) == .orderedAscending
            }
        }
    }

    /// Without history, rotation reads the server's lifetime play count,
    /// so the view still orders something before the history lands or
    /// from a snapshot taken before it was saved.
    private func key(_ album: PlexAlbum, rotation: Rotation) -> Double? {
        switch self {
        case .addedAt: album.addedAt.map(Double.init)
        case .lastPlayedAscending: album.lastViewedAt.map(Double.init)
        case .releaseDate: album.releaseOrdinal
        case .rotation: rotation.isEmpty ? album.viewCount.map(Double.init) : rotation.albums[album.ratingKey]
        }
    }

    private func key(_ artist: PlexArtist, rotation: Rotation) -> Double? {
        switch self {
        case .addedAt: artist.addedAt.map(Double.init)
        case .lastPlayedAscending: artist.lastViewedAt.map(Double.init)
        case .rotation: rotation.isEmpty ? artist.viewCount.map(Double.init) : rotation.artists[artist.ratingKey]
        case .releaseDate: nil
        }
    }
}

/// How `AlbumView` sections the sorted albums.
enum AlbumGrouping: Sendable {
    case none, artist, lastPlayed
}

/// One section of the browse root.
public struct AlbumGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let albums: [PlexAlbum]
}

/// Grouping and search for the browse root. All of it runs on the client:
/// the whole section is one request, and re-deriving the list from that
/// array is far cheaper than a round trip per option change.
public enum AlbumBrowse {
    /// Groups the albums that survive `hidden` under `view`, each group's
    /// albums in the view's sort order. A flat view yields one nameless
    /// group so the caller has a single shape to render. Artist groups run
    /// A–Z; recency groups run from Never Played to Today, so the least
    /// touched part of the library is at the top.
    public static func groups(
        _ albums: [PlexAlbum],
        view: AlbumView,
        hiding hidden: Set<String> = [],
        rotation: Rotation = .none,
        now: Date = .now
    ) -> [AlbumGroup] {
        let sorted = view.sort.sorted(albums.filter { !hidden.contains($0.artistKey) }, rotation: rotation)
        var order: [String] = []
        var members: [String: [PlexAlbum]] = [:]
        var names: [String: String] = [:]
        var ranks: [String: Int] = [:]
        for album in sorted {
            let (key, name, rank) = key(for: album, grouping: view.grouping, now: now)
            if members[key] == nil {
                order.append(key)
                names[key] = name
                ranks[key] = rank
            }
            members[key, default: []].append(album)
        }
        let groups = order.map { AlbumGroup(id: $0, name: names[$0] ?? "", albums: members[$0] ?? []) }
        switch view.grouping {
        case .none:
            return groups
        case .artist:
            return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastPlayed:
            return groups.sorted { (ranks[$0.id] ?? 0) > (ranks[$1.id] ?? 0) }
        }
    }

    /// The group an album belongs to. `rank` orders the recency groups.
    private static func key(
        for album: PlexAlbum,
        grouping: AlbumGrouping,
        now: Date
    ) -> (key: String, name: String, rank: Int) {
        switch grouping {
        case .none:
            ("all", "", 0)
        case .artist:
            (album.artistKey, album.parentTitle ?? "Unknown Artist", 0)
        case .lastPlayed:
            {
                let bucket = RecencyBucket(seconds: album.lastViewedAt, now: now)
                return ("played:\(bucket.rawValue)", bucket.title, bucket.rawValue)
            }()
        }
    }

    /// Flat search results, best match first. Prefix beats word-prefix
    /// beats internal, and at each level an album title beats an artist
    /// name, so typing "re" surfaces "Revolver" above every Red Hot Chili
    /// Peppers record. Ties keep the view's sort order.
    public static func search(
        _ albums: [PlexAlbum],
        query: String,
        view: AlbumView,
        hiding hidden: Set<String> = [],
        rotation: Rotation = .none
    ) -> [PlexAlbum] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let ranked: [(rank: Int, album: PlexAlbum)] = view.sort.sorted(albums, rotation: rotation).compactMap { album in
            guard !hidden.contains(album.artistKey) else { return nil }
            let title = MatchQuality(album.title, needle)
            let artist = MatchQuality(album.parentTitle ?? "", needle)
            guard let best = [title.map { $0.rawValue * 2 }, artist.map { $0.rawValue * 2 + 1 }]
                .compactMap({ $0 }).min() else { return nil }
            return (best, album)
        }
        // Stable sort keeps the sort order within a rank.
        return ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.album)
    }

    /// Where the query sits in the text, best first.
    enum MatchQuality: Int, Comparable {
        case prefix, wordPrefix, inside

        init?(_ text: String, _ needle: String) {
            let text = text.lowercased()
            guard let range = text.range(of: needle) else { return nil }
            if range.lowerBound == text.startIndex {
                self = .prefix
            } else if !text[text.index(before: range.lowerBound)].isLetter {
                self = .wordPrefix
            } else {
                self = .inside
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

/// "Last Week", "It's Been a While"… for the Back Catalog view.
public enum RecencyBucket: Int, CaseIterable, Sendable {
    case today, pastWeek, pastMonth, pastSixMonths, pastYear, earlier, never

    public var title: String {
        switch self {
        case .today: "Played Today"
        case .pastWeek: "Last Week"
        case .pastMonth: "Last Month"
        case .pastSixMonths: "Last 6 Months"
        case .pastYear: "Last Year"
        case .earlier: "It's Been a While"
        case .never: "Never Played"
        }
    }

    public init(seconds: Int?, now: Date = .now) {
        guard let seconds else { self = .never; return }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(seconds)))
        let day: TimeInterval = 86_400
        switch age {
        case ..<day: self = .today
        case ..<(7 * day): self = .pastWeek
        case ..<(30 * day): self = .pastMonth
        case ..<(182 * day): self = .pastSixMonths
        case ..<(365 * day): self = .pastYear
        default: self = .earlier
        }
    }
}

extension PlexAlbum {
    /// What the roster hides by and what the artist grouping keys on.
    public var artistKey: String { parentRatingKey ?? parentTitle ?? ratingKey }

    /// `originallyAvailableAt` as a sortable number, falling back to the
    /// year alone. `2014-04-08` → 20140408; `2014` → 20140000.
    var releaseOrdinal: Double? {
        if let date = originallyAvailableAt,
           let value = Double(date.filter(\.isNumber)),
           date.count == 10 {
            return value
        }
        return year.map { Double($0) * 10_000 }
    }
}
