import AppIntents
import PlexKit

/// A playlist as Siri and Shortcuts see it: the name to speak and the
/// rating key to play. The id is the rating key alone for now; S2 decides
/// whether the entity ids carry the server too.
struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistQuery()

    let id: String
    let title: String

    init(_ playlist: PlexPlaylist) {
        id = playlist.ratingKey
        title = playlist.title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
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
        return AlbumView.artist.sorted(await playback.playlists()).map(PlaylistEntity.init)
    }
}
