import Foundation

/// How the browse root orders albums. Raw values are persisted, so keep them
/// stable.
public enum AlbumSort: String, CaseIterable, Sendable, Codable {
    case recentlyAdded, lastPlayed, releaseDate, name, playCount

    public var title: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .lastPlayed: "Last Played"
        case .releaseDate: "Release Date"
        case .name: "Name"
        case .playCount: "Play Count"
        }
    }

    /// Stable ordering: albums missing the key sort to the bottom, ties fall
    /// back to title so the order doesn't shift between loads.
    func sorted(_ albums: [PlexAlbum]) -> [PlexAlbum] {
        sorted(albums, key: key, title: \.title)
    }

    /// The same options for artists. An artist has no release date, so that
    /// sort reads as Name here rather than vanishing from the menu.
    public func sorted(_ artists: [PlexArtist]) -> [PlexArtist] {
        sorted(artists, key: key, title: \.title)
    }

    private func sorted<T>(_ items: [T], key: (T) -> Double?, title: (T) -> String) -> [T] {
        items.sorted { lhs, rhs in
            switch (key(lhs), key(rhs)) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return title(lhs).localizedCaseInsensitiveCompare(title(rhs)) == .orderedAscending
            }
        }
    }

    /// Higher sorts first; nil sorts last. Name has no key, so `sorted`
    /// falls through to the title comparison for every pair.
    private func key(_ album: PlexAlbum) -> Double? {
        switch self {
        case .recentlyAdded: album.addedAt.map(Double.init)
        case .lastPlayed: album.lastViewedAt.map(Double.init)
        case .releaseDate: album.releaseOrdinal
        case .playCount: album.viewCount.map(Double.init)
        case .name: nil
        }
    }

    private func key(_ artist: PlexArtist) -> Double? {
        switch self {
        case .recentlyAdded: artist.addedAt.map(Double.init)
        case .lastPlayed: artist.lastViewedAt.map(Double.init)
        case .playCount: artist.viewCount.map(Double.init)
        case .releaseDate, .name: nil
        }
    }
}

/// How the browse root sections the sorted albums.
public enum AlbumGrouping: String, CaseIterable, Sendable, Codable {
    case none, artist, releaseYear, genre, lastPlayed

    public var title: String {
        switch self {
        case .none: "None"
        case .artist: "Artist"
        case .releaseYear: "Release Year"
        case .genre: "Genre"
        case .lastPlayed: "Last Played"
        }
    }
}

/// One section of the browse root.
public struct AlbumGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let albums: [PlexAlbum]
}

/// Sorting, grouping and search for the browse root. All of it runs on the
/// client: the whole section is one request, and re-deriving the list from
/// that array is far cheaper than a round trip per option change.
public enum AlbumBrowse {
    /// Groups the albums that survive `hidden`, each group's albums in sort
    /// order. No grouping yields one nameless group so the view has a single
    /// shape to render. Artist and genre groups follow the sort too (by their top
    /// album, or by name under the Name sort); year and recency groups are
    /// always in their natural order, since "2019 before 1997 because I
    /// played it more" reads as broken.
    public static func groups(
        _ albums: [PlexAlbum],
        sort: AlbumSort,
        grouping: AlbumGrouping,
        hiding hidden: Set<String> = [],
        now: Date = .now
    ) -> [AlbumGroup] {
        let sorted = sort.sorted(albums.filter { !hidden.contains($0.artistKey) })
        var order: [String] = []
        var members: [String: [PlexAlbum]] = [:]
        var names: [String: String] = [:]
        var ranks: [String: Int] = [:]
        for album in sorted {
            for (key, name, rank) in keys(for: album, grouping: grouping, now: now) {
                if members[key] == nil {
                    order.append(key)
                    names[key] = name
                    ranks[key] = rank
                }
                members[key, default: []].append(album)
            }
        }
        let groups = order.map { AlbumGroup(id: $0, name: names[$0] ?? "", albums: members[$0] ?? []) }
        switch grouping {
        case .none:
            return groups
        case .artist, .genre:
            guard sort == .name else { return groups }
            return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .releaseYear, .lastPlayed:
            return groups.sorted { (ranks[$0.id] ?? 0) < (ranks[$1.id] ?? 0) }
        }
    }

    /// Every group an album belongs to: one for most groupings, one per
    /// genre for genre. `rank` orders the natural-order groupings.
    private static func keys(
        for album: PlexAlbum,
        grouping: AlbumGrouping,
        now: Date
    ) -> [(key: String, name: String, rank: Int)] {
        switch grouping {
        case .none:
            return [("all", "", 0)]
        case .artist:
            return [(album.artistKey, album.parentTitle ?? "Unknown Artist", 0)]
        case .genre:
            let genres = album.genres.isEmpty ? ["No Genre"] : album.genres
            return genres.map { ($0, $0, 0) }
        case .releaseYear:
            guard let year = album.year else { return [("year:none", "Unknown Year", Int.max)] }
            return [("year:\(year)", String(year), -year)]
        case .lastPlayed:
            let bucket = RecencyBucket(seconds: album.lastViewedAt, now: now)
            return [("played:\(bucket.rawValue)", bucket.title, bucket.rawValue)]
        }
    }

    /// Flat search results, best match first. Prefix beats word-prefix
    /// beats internal, and at each level an album title beats an artist
    /// name, so typing "re" surfaces "Revolver" above every Red Hot Chili
    /// Peppers record. Ties keep the current sort order.
    public static func search(
        _ albums: [PlexAlbum],
        query: String,
        sort: AlbumSort,
        hiding hidden: Set<String> = []
    ) -> [PlexAlbum] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let ranked: [(rank: Int, album: PlexAlbum)] = sort.sorted(albums).compactMap { album in
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

/// "Past week", "Past month"… for the Last Played grouping.
public enum RecencyBucket: Int, CaseIterable, Sendable {
    case today, pastWeek, pastMonth, pastSixMonths, pastYear, earlier, never

    public var title: String {
        switch self {
        case .today: "Today"
        case .pastWeek: "Past Week"
        case .pastMonth: "Past Month"
        case .pastSixMonths: "Past 6 Months"
        case .pastYear: "Past Year"
        case .earlier: "Earlier"
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
