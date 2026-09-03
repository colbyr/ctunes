import Foundation

/// Everything the server returns is wrapped in one of these.
struct MediaContainerResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        let size: Int?
        let metadata: [Item]?
        let directory: [Item]?

        enum CodingKeys: String, CodingKey {
            case size
            case metadata = "Metadata"
            case directory = "Directory"
        }
    }

    let mediaContainer: Container

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    var items: [Item] { mediaContainer.metadata ?? mediaContainer.directory ?? [] }
}

/// A music library. Audiobooks also report type "artist", so a server can
/// have more than one and the user has to pick.
public struct PlexSection: Decodable, Sendable, Identifiable, Hashable {
    public let key: String
    public let type: String
    public let title: String

    public var id: String { key }
    public var isMusic: Bool { type == "artist" }
}

public struct PlexArtist: Decodable, Sendable, Identifiable, Hashable {
    public let ratingKey: String
    public let title: String
    public let thumb: String?
    /// Unix seconds when the artist entered the library.
    public let addedAt: Int?
    /// Unix seconds of the last play of anything by them.
    public let lastViewedAt: Int?
    /// Total track plays across the artist.
    public let viewCount: Int?

    public var id: String { ratingKey }

    public init(ratingKey: String, title: String, thumb: String? = nil,
                addedAt: Int? = nil, lastViewedAt: Int? = nil, viewCount: Int? = nil) {
        self.ratingKey = ratingKey
        self.title = title
        self.thumb = thumb
        self.addedAt = addedAt
        self.lastViewedAt = lastViewedAt
        self.viewCount = viewCount
    }
}

public struct PlexAlbum: Decodable, Sendable, Identifiable, Hashable {
    public let ratingKey: String
    public let title: String
    public let parentRatingKey: String?
    public let parentTitle: String?
    public let year: Int?
    public let thumb: String?
    /// Unix seconds when the album entered the library.
    public let addedAt: Int?
    /// Unix seconds of the last time any track on it was played.
    public let lastViewedAt: Int?
    /// Total track plays across the album.
    public let viewCount: Int?
    /// `yyyy-MM-dd`, finer than `year` when the server has it.
    public let originallyAvailableAt: String?
    public let genres: [String]

    public var id: String { ratingKey }

    public init(
        ratingKey: String,
        title: String,
        parentRatingKey: String? = nil,
        parentTitle: String?,
        year: Int?,
        thumb: String?,
        addedAt: Int? = nil,
        lastViewedAt: Int? = nil,
        viewCount: Int? = nil,
        originallyAvailableAt: String? = nil,
        genres: [String] = []
    ) {
        self.ratingKey = ratingKey
        self.title = title
        self.parentRatingKey = parentRatingKey
        self.parentTitle = parentTitle
        self.year = year
        self.thumb = thumb
        self.addedAt = addedAt
        self.lastViewedAt = lastViewedAt
        self.viewCount = viewCount
        self.originallyAvailableAt = originallyAvailableAt
        self.genres = genres
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        title = try c.decode(String.self, forKey: .title)
        parentRatingKey = try c.decodeIfPresent(String.self, forKey: .parentRatingKey)
        parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        addedAt = try c.decodeIfPresent(Int.self, forKey: .addedAt)
        lastViewedAt = try c.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        originallyAvailableAt = try c.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        genres = try c.decodeIfPresent([PlexTag].self, forKey: .genres)?.map(\.tag) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, title, parentRatingKey, parentTitle, year, thumb
        case addedAt, lastViewedAt, viewCount, originallyAvailableAt
        case genres = "Genre"
    }
}

/// `{"tag": "Pop/Rock"}` — how Plex lists genres, styles and moods.
struct PlexTag: Decodable, Sendable, Hashable {
    let tag: String
}

public struct PlexTrack: Decodable, Sendable, Identifiable, Hashable {
    public let ratingKey: String
    public let title: String
    public let index: Int?
    /// Milliseconds.
    public let duration: Int?
    /// The artist's ratingKey; matches `PlexAlbum.parentRatingKey`.
    public let grandparentRatingKey: String?
    public let grandparentTitle: String?
    /// The album's ratingKey; matches `PlexAlbum.ratingKey`.
    public let parentRatingKey: String?
    public let parentTitle: String?
    /// The disc number. Plex numbers discs from 1 and sends it for every
    /// track, single-disc albums included.
    public let parentIndex: Int?
    /// The track's own artist when it differs from the album artist — the
    /// credited artist on a compilation, or a featured guest. Plex reuses the
    /// `originalTitle` field for this and omits it otherwise.
    public let originalTitle: String?
    public let thumb: String?
    /// Plex's 0–10 star scale; absent when never rated.
    public let userRating: Double?
    public let media: [PlexMedia]?

    public var id: String { ratingKey }

    /// The credited artist when it differs from the album artist, else nil.
    public var trackArtist: String? {
        guard let originalTitle, !originalTitle.isEmpty, originalTitle != grandparentTitle else { return nil }
        return originalTitle
    }

    /// The app treats ratings as binary: a full 10 is a favorite, anything else is
    /// not. Lower stars set by other clients are deliberately not favorites.
    public var isFavorite: Bool { (userRating ?? 0) >= 10 }

    /// The file to stream. Direct play only — every track in the library
    /// decodes natively on iOS, so there is no transcode fallback yet.
    public var part: PlexPart? { media?.first?.parts?.first }

    public var durationSeconds: Double? {
        duration.map { Double($0) / 1000 }
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, title, index, duration, grandparentRatingKey, grandparentTitle
        case parentRatingKey, parentTitle, parentIndex, originalTitle, thumb, userRating
        case media = "Media"
    }
}

extension PlexTrack {
    /// Artist, then album: the grouping every shuffle in the app spreads by.
    public static let shuffleGrouping: [@Sendable (PlexTrack) -> String] =
        [{ $0.grandparentRatingKey ?? "" }, { $0.parentRatingKey ?? "" }]
}

extension Array where Element == PlexTrack {
    /// Spread-shuffled by artist, then album. See `SpreadShuffle.swift`.
    public func spreadShuffled() -> [PlexTrack] {
        spreadShuffled(by: PlexTrack.shuffleGrouping)
    }
}

public struct PlexMedia: Decodable, Sendable, Hashable {
    public let audioCodec: String?
    public let container: String?
    public let bitrate: Int?
    public let parts: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case audioCodec, container, bitrate
        case parts = "Part"
    }
}

public struct PlexPart: Decodable, Sendable, Hashable {
    public let key: String
    public let container: String?
    public let size: Int?

    public init(key: String, container: String? = nil, size: Int? = nil) {
        self.key = key
        self.container = container
        self.size = size
    }

    /// The file name the track cache stores this part under:
    /// `/library/parts/1017/1746246593/file.flac` → `1017-1746246593.flac`.
    /// The middle segment is the file's modification stamp, so the name
    /// changes when the file is replaced and a cached copy never needs
    /// revalidating. Only that exact shape is accepted; anything else is nil
    /// and the track streams. The real extension is kept because
    /// AVFoundation sniffs the container from it first.
    public var cacheKey: String? {
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 6, segments[0].isEmpty,
              segments[1] == "library", segments[2] == "parts",
              segments[3].allSatisfy(\.isNumber), !segments[3].isEmpty,
              segments[4].allSatisfy(\.isNumber), !segments[4].isEmpty
        else { return nil }
        let name = segments[5]
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex
        else { return nil }
        let ext = name[name.index(after: dot)...]
        guard ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "\(segments[3])-\(segments[4]).\(ext)"
    }
}

/// One part file the track cache can fetch. `request` carries the token in a
/// header, so nothing secret ends up in a path on disk; the cache stores the
/// file under `server/cacheKey`.
public struct TrackSource: Sendable, Hashable {
    /// `PlexServer.machineIdentifier`, so part ids from different servers
    /// can't collide.
    public let server: String
    public let part: PlexPart
    public let request: URLRequest

    public init(server: String, part: PlexPart, request: URLRequest) {
        self.server = server
        self.part = part
        self.request = request
    }

    public var expectedSize: Int? { part.size }

    /// `server/1017-1746246593.flac`; nil when the part key isn't cacheable.
    public var cachePath: String? {
        part.cacheKey.map { "\(server)/\($0)" }
    }
}
