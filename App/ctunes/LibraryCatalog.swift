import Foundation
import Observation
import PlexKit

/// The section as the browse root loaded it, shared with the search page
/// so opening search never fetches the library a second time, and with
/// Siri, whose value query resolves "play Loveless" against it. The root
/// writes it on every load; the search page only reads. It lives on
/// `AppRuntime` rather than the view because an intent can fire with no
/// window, in which case `load(from:section:)` fills it the way the root
/// would have.
@MainActor @Observable
final class LibraryCatalog {
    var albums: [PlexAlbum] = []
    var artists: [PlexArtist] = []
    var rotation: Rotation = .none
    /// Every hearted track, fetched with the albums so the favorites
    /// shortcut and the playlists page can say how many; nil until the
    /// request lands.
    var favorites: [PlexTrack]?
    var loaded = false

    /// Back to nothing, for a library switch.
    func reset() {
        albums = []
        artists = []
        rotation = .none
        favorites = nil
        loaded = false
    }

    /// The browse root's own fetches, for a caller with no root on screen:
    /// albums first (the one that has to land), then the history the
    /// rotation is scored from and the artists, both optional as on the
    /// root. Does nothing once loaded; the root refreshes on its own.
    func load(from library: any LibrarySource, section: PlexSection) async throws {
        guard !loaded else { return }
        async let plays = library.playHistory(inSection: section.key, since: .now - Rotation.window)
        async let artistList = library.artists(inSection: section.key)
        let albums = try await library.albums(inSection: section.key)
        self.albums = albums
        loaded = true
        rotation = Rotation(history: (try? await plays) ?? [], albums: albums)
        artists = (try? await artistList) ?? []
    }
}
