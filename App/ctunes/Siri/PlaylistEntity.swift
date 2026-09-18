import AppIntents
import PlexKit

/// A playlist as Siri and Shortcuts see it: the name to speak and the
/// rating key to play, under the `.audio.playlist` schema so it is one of
/// the things "play X" can resolve to as well as the App Shortcuts'
/// parameter. The id carries the server (`SiriID`).
@AppEntity(schema: .audio.playlist)
struct PlaylistEntity {
    static let defaultQuery = PlaylistQuery()

    let id: String
    var title: String
    // The schema asks for these three; a Plex playlist is the account's
    // own, and a smart one is the nearest thing to curated.
    var owner: PlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?
    let ratingKey: String

    // The schema's properties are wrapped, so the plain ones come first.
    init(_ playlist: PlexPlaylist, server: String) {
        id = SiriID.make(server: server, ratingKey: playlist.ratingKey)
        ratingKey = playlist.ratingKey
        title = playlist.title
        owner = nil
        createdByMe = true
        curatedForMe = playlist.smart
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// The schema's owner: a person or a name. Never set, since Plex tells
/// the app nothing about who made a playlist.
@UnionValue
enum PlaylistOwner {
    case person(IntentPerson)
    case name(String)
}

/// The section's playlists, A to Z. `suggestedEntities` is what Siri
/// learns the names from when the shortcuts register, so it is refreshed
/// whenever the list changes (`AppRuntime.followPlaylists`); the string
/// match is for a name Siri heard that wasn't registered yet.
struct PlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let playlists = try await all()
        return identifiers.compactMap { id in playlists.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let words = string.split(separator: " ").map { $0.lowercased() }
        return try await all().filter { entity in
            let title = entity.title.lowercased()
            let titleWords = title.split(separator: " ").map(String.init)
            return title.contains(string.lowercased())
                || words.allSatisfy { word in titleWords.contains { $0.hasPrefix(word) } }
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await all()
    }

    @MainActor
    private func all() async throws -> [PlaylistEntity] {
        let playback = try await IntentPlayback.ready()
        let server = playback.server
        return AlbumView.artist.sorted(await playback.playlists()).map { PlaylistEntity($0, server: server) }
    }
}
