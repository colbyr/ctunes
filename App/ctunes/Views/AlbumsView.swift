import PlexKit
import SwiftUI

struct AlbumsView: View {
    let model: AppModel
    let section: PlexSection
    let artist: PlexArtist

    @State private var albums: [PlexAlbum] = []
    @State private var loaded = false

    var body: some View {
        List(albums) { album in
            NavigationLink(value: album) {
                HStack(spacing: 12) {
                    Artwork(url: model.library?.artworkURL(album.thumb))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                        if let year = album.year {
                            Text(String(year)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if !loaded { ProgressView() }
            else if albums.isEmpty { ContentUnavailableView("No albums", systemImage: "square.stack") }
        }
        .navigationTitle(artist.title)
        .navigationDestination(for: PlexAlbum.self) { album in
            TracksView(model: model, album: album)
        }
        .task {
            guard let library = model.library else { return }
            albums = (try? await library.albums(
                forArtist: artist.ratingKey, inSection: section.key)) ?? []
            loaded = true
        }
    }
}
