import PlexKit
import SwiftUI

struct ArtistsView: View {
    let model: AppModel
    let section: PlexSection

    @State private var artists: [PlexArtist] = []
    @State private var loaded = false

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    Artwork(url: model.library?.artworkURL(artist.thumb))
                    Text(artist.title)
                }
            }
        }
        .overlay {
            if !loaded { ProgressView() }
            else if artists.isEmpty { ContentUnavailableView("No artists", systemImage: "music.mic") }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.sections.count > 1 {
                        Button("Change library") { model.clearSectionChoice() }
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(for: PlexArtist.self) { artist in
            AlbumsView(model: model, section: section, artist: artist)
        }
        .task {
            guard let library = model.library else { return }
            artists = (try? await library.artists(inSection: section.key)) ?? []
            loaded = true
        }
    }
}
