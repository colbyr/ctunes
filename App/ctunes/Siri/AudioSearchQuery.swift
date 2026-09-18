import AppIntents
import MediaIntents
import os
import PlexKit

/// The Siri layer's log, read on a phone with
/// `log collect --device-udid … ` then `log show --predicate 'category == "Siri"'`.
let siriLog = Logger(subsystem: "com.colbyr.ctunes", category: "Siri")

/// The search Siri runs for "play X": handed an `AudioSearch`, answers
/// with the artists, albums, playlists and songs that match, best first,
/// and Siri picks from them. Nothing is indexed ahead of time; this is
/// the search page's own ranking (`LibrarySearch.hits`) over the catalog
/// the browse root loads, the playlists and the server's track search,
/// minus what the active listeners veto. Offline the same ranking runs
/// over the snapshot and the tracks on disk, as the search page does.
struct AudioSearchQuery: IntentValueQuery {
    /// How many of each kind to hand Siri. A dozen is plenty for a pick;
    /// every song an artist's name matches would be noise.
    static let limit = 12

    @MainActor
    func values(for input: AudioSearch) async throws -> [AudioEntity] {
        siriLog.info("search asked: \(String(describing: input.criteria), privacy: .public)")
        let playback = try await IntentPlayback.ready()
        let hits: [AudioEntity]
        switch input.criteria {
        case .searchQuery(let query):
            hits = try await playback.search(query)
        case .unspecified:
            // "Play music": the top of On Rotation, so Siri has a pick.
            let server = playback.server
            hits = try await playback.rotationAlbums().prefix(Self.limit).map { .album(AlbumEntity($0, server: server)) }
        case .url:
            hits = []
        @unknown default:
            hits = []
        }
        siriLog.info("search answered \(hits.count) hits: \(hits.prefix(6).map(\.logName).joined(separator: "; "), privacy: .public)")
        return hits
    }
}

// The per-type queries, which resolve ids Siri hands back: an artist or
// album from the catalog, a playlist from the model's list, a song from
// the server by rating key. Each is an `EntityStringQuery` too, the
// schema's condition for a union case with no index, answering a name
// with the value query's hits of its own kind. `suggestedEntities` is
// empty for all but the playlist: a library is thousands of names, and
// Siri finds them through the value query above.

struct ArtistQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [ArtistEntity] {
        try await IntentPlayback.ready().search(string).compactMap {
            if case .artist(let artist) = $0 { artist } else { nil }
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        let playback = try await IntentPlayback.ready()
        let artists = try await playback.artists()
        return identifiers.compactMap { id in
            guard let key = SiriID.ratingKey(of: id, server: playback.server) else { return nil }
            return artists.first { $0.ratingKey == key }.map { ArtistEntity($0, server: playback.server) }
        }
    }

    func suggestedEntities() async throws -> [ArtistEntity] { [] }
}

struct AlbumQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [AlbumEntity] {
        try await IntentPlayback.ready().search(string).compactMap {
            if case .album(let album) = $0 { album } else { nil }
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        let playback = try await IntentPlayback.ready()
        let albums = try await playback.albums()
        return identifiers.compactMap { id in
            guard let key = SiriID.ratingKey(of: id, server: playback.server) else { return nil }
            return albums.first { $0.ratingKey == key }.map { AlbumEntity($0, server: playback.server) }
        }
    }

    func suggestedEntities() async throws -> [AlbumEntity] { [] }
}

struct SongQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [SongEntity] {
        try await IntentPlayback.ready().search(string).compactMap {
            if case .song(let song) = $0 { song } else { nil }
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SongEntity] {
        let playback = try await IntentPlayback.ready()
        var songs: [SongEntity] = []
        for id in identifiers {
            guard let key = SiriID.ratingKey(of: id, server: playback.server) else { continue }
            if let track = try await playback.track(ratingKey: key) {
                songs.append(SongEntity(track, server: playback.server))
            }
        }
        return songs
    }

    func suggestedEntities() async throws -> [SongEntity] { [] }
}
