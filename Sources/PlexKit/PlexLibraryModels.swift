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

    public var id: String { ratingKey }
}

public struct PlexAlbum: Decodable, Sendable, Identifiable, Hashable {
    public let ratingKey: String
    public let title: String
    public let parentRatingKey: String?
    public let parentTitle: String?
    public let year: Int?
    public let thumb: String?

    public var id: String { ratingKey }

    public init(
        ratingKey: String,
        title: String,
        parentRatingKey: String? = nil,
        parentTitle: String?,
        year: Int?,
        thumb: String?
    ) {
        self.ratingKey = ratingKey
        self.title = title
        self.parentRatingKey = parentRatingKey
        self.parentTitle = parentTitle
        self.year = year
        self.thumb = thumb
    }
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
    public let parentTitle: String?
    public let thumb: String?
    /// Plex's 0–10 star scale; absent when never rated.
    public let userRating: Double?
    public let media: [PlexMedia]?

    public var id: String { ratingKey }

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
        case ratingKey, title, index, duration, grandparentRatingKey, grandparentTitle, parentTitle, thumb, userRating
        case media = "Media"
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
}
