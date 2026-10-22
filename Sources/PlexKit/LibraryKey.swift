import Foundation

/// One saved request of a library: the unit the offline store keeps and
/// dates. The section's lists, and the per-item lists any page asks for.
/// Each is written only from its own successful response, so a failed
/// fetch can never overwrite another's, and each has its own age, so a
/// library can tell what is worth asking the server about again.
public enum LibraryKey: Hashable, Sendable {
    /// The section's albums, artists, favorites, play history and playlists.
    case albums, artists, favorites, history, playlists
    /// An album's tracks, an artist's albums and tracks, a playlist's items.
    /// Kept under the server rather than the section: a rating key is the
    /// server's, and the pins file their lists in the same place.
    case albumTracks(String), artistAlbums(String), artistTracks(String), playlistItems(String)

    /// Whether the key is one of the section's lists.
    public var isSectionScoped: Bool {
        switch self {
        case .albums, .artists, .favorites, .history, .playlists: true
        case .albumTracks, .artistAlbums, .artistTracks, .playlistItems: false
        }
    }
}

/// What opening a server's library with no network needs, written on
/// every connect: the name, the music sections, and the address the lists
/// were fetched over, so offline artwork can ask the image cache for the
/// URLs it saw online. No token.
public struct ServerRecord: Codable, Sendable, Equatable {
    public let name: String
    public let sections: [PlexSection]
    public let baseURL: URL?

    public init(name: String, sections: [PlexSection], baseURL: URL?) {
        self.name = name
        self.sections = sections
        self.baseURL = baseURL
    }
}
