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
    var albums: [PlexAlbum] = [] {
        didSet {
            guard albums != oldValue else { return }
            byArtist = AlbumBrowse.groups(albums, view: .artist)
            albumsByArtistKey = Dictionary(grouping: albums, by: \.artistKey)
            revision += 1
        }
    }
    var artists: [PlexArtist] = [] {
        didSet { if artists != oldValue { revision += 1 } }
    }
    var rotation: Rotation = .none {
        didSet { if rotation != oldValue { revision += 1 } }
    }
    /// Bumped when the albums, the artists or the rotation change, not on
    /// every load that hands back the same lists: what the browse root
    /// keys its grouping on, so a redraw doesn't sort the library again.
    private(set) var revision = 0
    /// Every album grouped under its artist, A to Z: the listeners sheet's
    /// and Settings' list. Worked out when the albums land rather than on
    /// every redraw of the root, which passes it down.
    private(set) var byArtist: [AlbumGroup] = []
    /// Each artist's albums in the section, by the artist's ratingKey.
    private(set) var albumsByArtistKey: [String: [PlexAlbum]] = [:]
    /// Every hearted track, fetched with the albums so the favorites
    /// shortcut and the Favorites tile can say how many; nil until the
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
