import Foundation

/// Apple Music items as the app's own shapes (COL-117, `notes/apple-music.md`).
///
/// A catalog song is a `PlexTrack` and a catalog album a `PlexAlbum`, told
/// apart by their keys, so the queue, its snapshot, Up Next, search's
/// recents and the album route carry them with no second type:
///
/// - a song's `ratingKey` is `am:<catalog song id>`;
/// - an album's is `am-album:<catalog album id>`, which is also the song's
///   `parentRatingKey` when its album is known;
/// - the artist key is **the library's own** when the library has that
///   artist (so the artist link, the spread shuffle and an artist veto
///   treat the song as theirs) and nil otherwise;
/// - `thumb` is an absolute URL, which `artworkURL` hands back untouched.
///
/// Such a track has no `media`, so the library's `availability` is `.none`
/// and nothing of the cache, the pins or the transcoder ever sees it.
public enum AppleMusicID {
    public static let songPrefix = "am:"
    public static let albumPrefix = "am-album:"

    public static func songKey(_ id: String) -> String { songPrefix + id }
    public static func albumKey(_ id: String) -> String { albumPrefix + id }

    /// The catalog id inside a key, nil for a library key.
    public static func song(in key: String) -> String? {
        key.hasPrefix(songPrefix) ? String(key.dropFirst(songPrefix.count)) : nil
    }

    public static func album(in key: String?) -> String? {
        guard let key, key.hasPrefix(albumPrefix) else { return nil }
        return String(key.dropFirst(albumPrefix.count))
    }

    /// An absolute `thumb` as its URL, nil for a server path. Apple's
    /// covers end in their pixel size (`…/600x600bb.jpg`), which is
    /// rewritten to the size asked, so a row doesn't pull a 900px cover.
    public static func artwork(_ thumb: String, size: Int) -> URL? {
        guard thumb.hasPrefix("https://") || thumb.hasPrefix("http://"), let url = URL(string: thumb) else { return nil }
        let name = url.lastPathComponent
        let digits = name.prefix { $0.isNumber }
        guard !digits.isEmpty, name.dropFirst(digits.count).hasPrefix("x") else { return url }
        let rest = name.dropFirst(digits.count + 1)
        let height = rest.prefix { $0.isNumber }
        guard !height.isEmpty else { return url }
        return url.deletingLastPathComponent().appending(path: "\(size)x\(size)" + rest.dropFirst(height.count))
    }

    /// The album id in a song's share link
    /// (`https://music.apple.com/us/album/<slug>/<album id>?i=<song id>`):
    /// a search result names its album by title only, and the relationship
    /// costs a request per song.
    public static func album(inSongURL url: URL?) -> String? {
        guard let url, url.pathComponents.contains("album"),
              let last = url.pathComponents.last, !last.isEmpty, last.allSatisfy(\.isNumber)
        else { return nil }
        return last
    }
}

extension PlexTrack {
    public var isAppleMusic: Bool { ratingKey.hasPrefix(AppleMusicID.songPrefix) }
    /// The catalog song id, nil for a library track.
    public var appleMusicID: String? { AppleMusicID.song(in: ratingKey) }

    /// A catalog song as a queue entry. `artistKey` is the library's key
    /// for the artist when it has them; `credited` the song's own artist
    /// where the album's is someone else (a compilation, a guest).
    public static func appleMusic(
        id: String, title: String, artist: String, artistKey: String? = nil, credited: String? = nil,
        album: String? = nil, albumID: String? = nil,
        index: Int? = nil, disc: Int? = nil, duration: Double? = nil, artwork: URL? = nil
    ) -> PlexTrack {
        PlexTrack(
            ratingKey: AppleMusicID.songKey(id), title: title, index: index,
            duration: duration.map { Int(($0 * 1000).rounded()) },
            grandparentRatingKey: artistKey, grandparentTitle: artist,
            parentRatingKey: albumID.map(AppleMusicID.albumKey), parentTitle: album,
            parentIndex: disc, originalTitle: credited, thumb: artwork?.absoluteString
        )
    }

    init(ratingKey: String, title: String, index: Int?, duration: Int?,
         grandparentRatingKey: String?, grandparentTitle: String?,
         parentRatingKey: String?, parentTitle: String?, parentIndex: Int?,
         originalTitle: String?, thumb: String?) {
        self.ratingKey = ratingKey
        self.title = title
        self.index = index
        self.duration = duration
        self.grandparentRatingKey = grandparentRatingKey
        self.grandparentTitle = grandparentTitle
        self.parentRatingKey = parentRatingKey
        self.parentTitle = parentTitle
        self.parentIndex = parentIndex
        self.originalTitle = originalTitle
        self.thumb = thumb
        self.userRating = nil
        self.lastRatedAt = nil
        self.media = nil
    }
}

extension PlexAlbum {
    public var isAppleMusic: Bool { ratingKey.hasPrefix(AppleMusicID.albumPrefix) }
    public var appleMusicID: String? { AppleMusicID.album(in: ratingKey) }

    public static func appleMusic(
        id: String, title: String, artist: String, artistKey: String? = nil,
        year: Int? = nil, trackCount: Int? = nil, artwork: URL? = nil
    ) -> PlexAlbum {
        PlexAlbum(
            ratingKey: AppleMusicID.albumKey(id), title: title,
            parentRatingKey: artistKey, parentTitle: artist,
            year: year, thumb: artwork?.absoluteString, leafCount: trackCount
        )
    }
}

/// Whether something from the catalog is already in the library, by name:
/// Plex rarely carries an ISRC or a UPC, so the artist and the title are
/// all there is. Deliberately loose about what the stores append ("Deluxe
/// Edition", "2011 Remaster", "- EP", "feat. …") and strict about the
/// rest, so "Weezer (Blue Album)" and "Weezer (Green Album)" stay two
/// albums. A miss shows something owned as an Apple Music result, marked;
/// a false match would hide something the library doesn't have, so the
/// rules err toward the miss.
public enum MusicMatch {
    /// A name folded for comparison: case, accents, "&", a leading "The",
    /// punctuation, and any bracket or dash suffix that only names an
    /// edition.
    public static func key(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        text = text.replacingOccurrences(of: "’", with: "'")
        text = strippingEditionBrackets(text)
        text = strippingEditionSuffix(text)
        text = text.replacingOccurrences(of: "&", with: " and ")
        var out = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar != "'" {
                // An apostrophe closes up ("don't" → "dont"); anything
                // else separates words.
                out.append(" ")
            }
        }
        var words = out.split(separator: " ")
        if words.count > 1, words.first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Artist and title as one key.
    public static func key(artist: String?, title: String) -> String {
        key(artist ?? "") + "\u{1F}" + key(title)
    }

    /// The library's albums and tracks, for asking `owns`.
    public struct Owned: Sendable {
        var albums: Set<String> = []
        var tracks: Set<String> = []
        /// Albums by title alone, for one artist's page, where the artist
        /// is already agreed and a store may credit "Artist & Guest".
        var albumTitles: Set<String> = []

        public init(albums: [PlexAlbum] = [], tracks: [PlexTrack] = []) {
            for album in albums where !album.isAppleMusic {
                self.albums.insert(MusicMatch.key(artist: album.parentTitle, title: album.title))
                albumTitles.insert(MusicMatch.key(album.title))
            }
            for track in tracks where !track.isAppleMusic {
                self.tracks.insert(MusicMatch.key(artist: track.grandparentTitle, title: track.title))
                if let credited = track.trackArtist {
                    self.tracks.insert(MusicMatch.key(artist: credited, title: track.title))
                }
            }
        }

        public func owns(album title: String, artist: String) -> Bool {
            albums.contains(MusicMatch.key(artist: artist, title: title))
        }

        /// By title alone: only among one artist's albums.
        public func owns(albumTitled title: String) -> Bool {
            albumTitles.contains(MusicMatch.key(title))
        }

        /// A song is owned when the library has that track, or the album
        /// it is on.
        public func owns(song title: String, artist: String, album: String?) -> Bool {
            if tracks.contains(MusicMatch.key(artist: artist, title: title)) { return true }
            if let album, owns(album: album, artist: artist) { return true }
            return false
        }
    }

    /// The library artist a catalog credit names, by folded name.
    public static func artistKey(for name: String, in artists: [PlexArtist]) -> String? {
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        return artists.first { key($0.title) == wanted }?.ratingKey
    }

    /// One album per folded title, the first kept: the catalog lists the
    /// clean and explicit pressings, and every reissue, as albums of
    /// their own.
    public static func uniqued<Item>(_ items: [Item], by title: (Item) -> String) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert(key(title($0))).inserted }
    }

    // MARK: - Editions

    /// Words that mark a bracket or a suffix as naming an edition of the
    /// same record rather than a different one.
    private static let editionWords: Set<String> = [
        "deluxe", "remaster", "remastered", "remasters", "edition", "version", "expanded", "anniversary",
        "bonus", "explicit", "clean", "mono", "stereo", "single", "ep", "reissue", "special", "legacy",
        "collector's", "collectors", "super", "feat", "feat.", "featuring", "ft", "ft.", "with",
    ]

    private static func namesEdition(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }).map(String.init)
        return words.contains { editionWords.contains($0) }
    }

    /// Drops "(…)" and "[…]" groups that name an edition; keeps the rest.
    private static func strippingEditionBrackets(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "[" {
                let close: Character = character == "(" ? ")" : "]"
                if let end = text[index...].firstIndex(of: close) {
                    let inside = String(text[text.index(after: index)..<end])
                    if namesEdition(inside) {
                        index = text.index(after: end)
                        continue
                    }
                }
            }
            out.append(character)
            index = text.index(after: index)
        }
        return out
    }

    /// Drops a trailing " - Single", " - EP", " - 2011 Remaster".
    private static func strippingEditionSuffix(_ text: String) -> String {
        guard let dash = text.range(of: " - ", options: .backwards) else { return text }
        let tail = String(text[dash.upperBound...])
        return namesEdition(tail) ? String(text[..<dash.lowerBound]) : text
    }
}
