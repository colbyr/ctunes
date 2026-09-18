import AppIntents
import PlexKit

// The library as Siri sees it: an artist, an album, a song and a playlist
// under the `.audio` app schema, so "Play Loveless by My Bloody Valentine"
// and "Shuffle Sunday Morning" resolve through `AudioSearchQuery` with no
// phrase registered ahead of time. Each is a mapping over the Plex DTO,
// since the schema fixes the property names (`title`, `artistName`,
// `artists`, `album`) and ours are `title`, `parentTitle`,
// `grandparentTitle`. The plan is `notes/siri.md`.

/// An entity id: the server's identifier and the rating key, since rating
/// keys are per server and an id Siri saved must not resolve to the wrong
/// thing after a server swap. Colon-separated; neither side holds one.
enum SiriID {
    static func make(server: String, ratingKey: String) -> String { "\(server):\(ratingKey)" }

    /// The rating key when the id belongs to `server`, else nil.
    static func ratingKey(of id: String, server: String) -> String? {
        guard let split = id.firstIndex(of: ":"), id[..<split] == server else { return nil }
        return String(id[id.index(after: split)...])
    }
}

@AppEntity(schema: .audio.artist)
struct ArtistEntity {
    static let defaultQuery = ArtistQuery()

    let id: String
    var name: String
    let ratingKey: String

    // The schema's properties are wrapped, so the plain ones come first,
    // in every init here.
    init(_ artist: PlexArtist, server: String) {
        id = SiriID.make(server: server, ratingKey: artist.ratingKey)
        ratingKey = artist.ratingKey
        name = artist.title
    }

    /// The artist as a track or album names it, when the library's own
    /// list isn't at hand.
    init(ratingKey: String, name: String, server: String) {
        id = SiriID.make(server: server, ratingKey: ratingKey)
        self.ratingKey = ratingKey
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@AppEntity(schema: .audio.album)
struct AlbumEntity {
    static let defaultQuery = AlbumQuery()

    let id: String
    var title: String
    var artistName: String
    var artists: [ArtistEntity]
    /// The schema asks for it; Plex has no UPC.
    var universalProductCode: String?
    let ratingKey: String

    init(_ album: PlexAlbum, server: String) {
        id = SiriID.make(server: server, ratingKey: album.ratingKey)
        ratingKey = album.ratingKey
        universalProductCode = nil
        title = album.title
        artistName = album.parentTitle ?? ""
        artists = album.parentRatingKey.map {
            [ArtistEntity(ratingKey: $0, name: album.parentTitle ?? "", server: server)]
        } ?? []
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)")
    }
}

@AppEntity(schema: .audio.song)
struct SongEntity {
    static let defaultQuery = SongQuery()

    let id: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var artists: [ArtistEntity]
    var album: AlbumEntity?
    /// The schema asks for these; a Plex track carries none of them.
    var composerName: String?
    var composers: [ArtistEntity]
    var internationalStandardRecordingCode: String?
    let ratingKey: String
    /// The album's rating key, which is how the song is fetched again and
    /// how it plays: the album from that song, as a search result does.
    let albumRatingKey: String?

    init(_ track: PlexTrack, server: String) {
        id = SiriID.make(server: server, ratingKey: track.ratingKey)
        ratingKey = track.ratingKey
        albumRatingKey = track.parentRatingKey
        title = track.title
        artistName = track.trackArtist ?? track.grandparentTitle ?? ""
        albumTitle = track.parentTitle
        artists = track.grandparentRatingKey.map {
            [ArtistEntity(ratingKey: $0, name: track.grandparentTitle ?? "", server: server)]
        } ?? []
        album = track.album.map { AlbumEntity($0, server: server) }
        composerName = nil
        composers = []
        internationalStandardRecordingCode = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)")
    }
}

/// What "play X" can name: the four kinds the library has. Siri picks
/// from what `AudioSearchQuery` returns and hands one back to
/// `PlayAudioIntent`.
@UnionValue
enum AudioEntity {
    case song(SongEntity)
    case album(AlbumEntity)
    case artist(ArtistEntity)
    case playlist(PlaylistEntity)
}

@AppEnum(schema: .audio.playbackAttributes)
enum PlaybackAttribute: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [PlaybackAttribute: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

@AppEnum(schema: .audio.queueInsertionLocation)
enum QueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [QueueInsertionLocation: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Add to Queue",
    ]
}
