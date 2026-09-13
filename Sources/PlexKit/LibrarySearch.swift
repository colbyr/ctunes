import Foundation

/// One hit on the search page: an artist, an album or a track, ranked
/// together in one list.
public enum SearchHit: Codable, Hashable, Sendable, Identifiable {
    case artist(PlexArtist)
    case album(PlexAlbum)
    case track(PlexTrack)

    public var id: String {
        switch self {
        case .artist(let artist): "artist:\(artist.ratingKey)"
        case .album(let album): "album:\(album.ratingKey)"
        case .track(let track): "track:\(track.ratingKey)"
        }
    }
}

/// The search page's ranking. Artists and albums are the section's own
/// lists, already on the phone; tracks come from the server's title
/// filter, which matches a word prefix in the track's title, its album or
/// its artist, so what it returns is re-ranked here rather than trusted.
public enum LibrarySearch {
    /// The mixed list, best match first. An item's own name counts most:
    /// a prefix beats a word prefix beats an inside match, and at each of
    /// those an artist beats an album beats a track. A match only through
    /// a parent (an album by the artist, a track off the album) follows,
    /// and a track the server matched some other way, on a word from each
    /// of two fields, say, comes last. Ties keep the lists' own order.
    /// Only the best `trackLimit` tracks are kept: an artist's name can
    /// match every track of theirs, and the artist row already covers them.
    public static func hits(
        artists: [PlexArtist],
        albums: [PlexAlbum],
        tracks: [PlexTrack],
        query: String,
        hiding hidden: VetoSet = VetoSet(),
        trackLimit: Int = 50
    ) -> [SearchHit] {
        let needle = Self.needle(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(rank: Int, kind: Int, index: Int, hit: SearchHit)] = []
        for (index, artist) in artists.enumerated() where !hidden.artists.contains(artist.ratingKey) {
            guard let rank = rank(own: artist.title, related: [], needle: needle) else { continue }
            ranked.append((rank, 0, index, .artist(artist)))
        }
        for (index, album) in albums.enumerated() where !hidden.hides(album) {
            guard let rank = rank(own: album.title, related: [album.parentTitle], needle: needle) else { continue }
            ranked.append((rank, 1, index, .album(album)))
        }
        for (index, track) in tracks.enumerated() where !hidden.hides(track) {
            let rank = rank(own: track.title, related: [track.parentTitle, track.grandparentTitle, track.originalTitle], needle: needle)
            ranked.append((rank ?? Rank.elsewhere, 2, index, .track(track)))
        }
        var tracksKept = 0
        return ranked
            .sorted { ($0.rank, $0.kind, $0.index) < ($1.rank, $1.kind, $1.index) }
            .compactMap { entry in
                if case .track = entry.hit {
                    guard tracksKept < trackLimit else { return nil }
                    tracksKept += 1
                }
                return entry.hit
            }
    }

    /// Names to finish the query with, the way a search field suggests
    /// terms: artists and album titles the query is part of, best match
    /// first, never the query itself, each name once.
    public static func completions(
        artists: [PlexArtist],
        albums: [PlexAlbum],
        query: String,
        hiding hidden: VetoSet = VetoSet(),
        limit: Int = 3
    ) -> [String] {
        let needle = Self.needle(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(rank: Int, kind: Int, index: Int, name: String)] = []
        for (index, artist) in artists.enumerated() where !hidden.artists.contains(artist.ratingKey) {
            if let quality = AlbumBrowse.MatchQuality(artist.title, needle) {
                ranked.append((quality.rawValue, 0, index, artist.title))
            }
        }
        for (index, album) in albums.enumerated() where !hidden.hides(album) {
            if let quality = AlbumBrowse.MatchQuality(album.title, needle) {
                ranked.append((quality.rawValue, 1, index, album.title))
            }
        }
        var seen: Set<String> = [needle]
        return ranked
            .sorted { ($0.rank, $0.kind, $0.index) < ($1.rank, $1.kind, $1.index) }
            .compactMap { seen.insert($0.name.lowercased()).inserted ? $0.name : nil }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether a track is what the server's title filter would return for
    /// the query: every word of the query starts a word of the title, the
    /// album, the artist or the credited artist. The offline library
    /// answers its searches with this over the tracks on disk.
    public static func matches(_ track: PlexTrack, query: String) -> Bool {
        let wanted = needle(query).split(whereSeparator: Self.isSeparator)
        guard !wanted.isEmpty else { return false }
        let words = [track.title, track.parentTitle, track.grandparentTitle, track.originalTitle]
            .compactMap { $0?.lowercased() }
            .flatMap { $0.split(whereSeparator: Self.isSeparator) }
        return wanted.allSatisfy { want in words.contains { $0.hasPrefix(want) } }
    }

    /// The query as it is matched: trimmed and case-folded.
    public static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private enum Rank {
        /// Matched through a parent's name, not the item's own.
        static let related = 3
        /// Returned by the server but matched by nothing the phone can see.
        static let elsewhere = 4
    }

    /// The item's own name by match quality, else a parent's by name at
    /// all, else nil.
    private static func rank(own: String, related: [String?], needle: String) -> Int? {
        if let quality = AlbumBrowse.MatchQuality(own, needle) { return quality.rawValue }
        if related.contains(where: { $0?.lowercased().contains(needle) == true }) { return Rank.related }
        return nil
    }

    private static func isSeparator(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber)
    }
}
