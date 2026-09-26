import Foundation
import Observation
import PlexKit

/// The `ctunes://` scheme, for the widgets' open surfaces: `mix/<id>`
/// opens a shortcut the way its chevron does (the thing itself for one
/// pick, the builder otherwise), `favorites` the Favorites page, and
/// `album/<ratingKey>`, `artist/<ratingKey>` and `playlist/<ratingKey>`
/// their pages when the catalog knows them. Parked here rather than
/// routed at once because a URL can arrive before the library stack
/// exists (a cold launch from a widget lands on the connecting screen);
/// `LibraryView` takes the route when it appears.
@MainActor
@Observable
final class DeepLinks {
    var route: LibraryRoute?

    func open(_ url: URL, model: AppModel, catalog: LibraryCatalog) {
        guard url.scheme == "ctunes" else { return }
        let key = url.pathComponents.dropFirst().first
        switch url.host() {
        case "favorites":
            route = .favorites
        case "mix":
            guard let key, let id = UUID(uuidString: key), let mix = model.shortcut(id) else { return }
            route = Self.route(for: mix, model: model, catalog: catalog)
        case "album":
            guard let album = catalog.albums.first(where: { $0.ratingKey == key }) else { return }
            route = .album(album)
        case "artist":
            guard let artist = catalog.artists.first(where: { $0.ratingKey == key }) else { return }
            route = .artist(ArtistRoute(ratingKey: artist.ratingKey, title: artist.title))
        case "playlist":
            guard let playlist = model.playlists.first(where: { $0.ratingKey == key }) else { return }
            route = .playlist(playlist)
        default:
            break
        }
    }

    /// One pick opens the thing itself; a mix of several, or of the
    /// whole library, opens the builder on its picks.
    private static func route(for mix: SavedMix, model: AppModel, catalog: LibraryCatalog) -> LibraryRoute {
        guard mix.picks.count == 1 else { return .mix(MixRoute(mixID: mix.id)) }
        switch mix.picks[0] {
        case .favorites:
            return .favorites
        case .playlist(let key, let title, _):
            return .playlist(model.playlists.first { $0.ratingKey == key } ?? PlexPlaylist(ratingKey: key, title: title))
        case .artist(let key, let title, _):
            return .artist(ArtistRoute(ratingKey: key, title: title))
        case .album(let key, let title, let artistKey, let artist, let thumb):
            return .album(catalog.albums.first { $0.ratingKey == key }
                ?? PlexAlbum(ratingKey: key, title: title, parentRatingKey: artistKey, parentTitle: artist, year: nil, thumb: thumb))
        }
    }
}
