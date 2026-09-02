import PlexKit
import SwiftUI

/// Browse root: every album in the library, grouped under its artist. The
/// query comes from the floating search pill and matches either name.
struct MusicView: View {
    let model: AppModel
    let section: PlexSection
    @Binding var query: String
    @Environment(AudioPlayer.self) private var player

    @State private var albums: [PlexAlbum] = []
    @State private var loaded = false
    @State private var loadingFavorites = false
    @State private var noFavorites = false

    private var groups: [ArtistGroup] { ArtistGroup.grouped(albums, matching: query) }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    Button(action: shuffleFavorites) {
                        HStack {
                            Label {
                                Text("Shuffle Favorites")
                            } icon: {
                                Image(systemName: "heart.fill").foregroundStyle(.pink)
                            }
                            Spacer()
                            if loadingFavorites {
                                ProgressView()
                            } else {
                                Image(systemName: "shuffle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(loadingFavorites)
                }
            }
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.albums) { album in
                        NavigationLink(value: album) {
                            AlbumRow(model: model, album: album)
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
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
        .task {
            guard let library = model.library else { return }
            albums = (try? await library.albums(inSection: section.key)) ?? []
            loaded = true
        }
        .alert("No favorites yet", isPresented: $noFavorites) {
            Button("OK") {}
        } message: {
            Text("Swipe a track left, or tap the heart in Now Playing, to favorite it.")
        }
    }

    /// Every favorite track in the library, in a fresh random order each tap.
    /// Shuffling once at enqueue time is all this needs; the player has no
    /// shuffle mode of its own.
    private func shuffleFavorites() {
        guard let library = model.library, !loadingFavorites else { return }
        loadingFavorites = true
        Task {
            defer { loadingFavorites = false }
            let favorites = (try? await library.favoriteTracks(inSection: section.key)) ?? []
            guard !favorites.isEmpty else {
                noFavorites = true
                return
            }
            player.play(favorites.shuffled(), startingAt: 0, library: library)
        }
    }
}

private struct AlbumRow: View {
    let model: AppModel
    let album: PlexAlbum

    var body: some View {
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

/// One artist's albums. Grouping happens on the client because the flat
/// section query is a single request; asking per artist would be one per row.
struct ArtistGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [PlexAlbum]

    /// Groups albums by artist and applies the search text. An artist-name
    /// match keeps the whole group; otherwise only the matching albums remain,
    /// so searching a title still shows who made it.
    static func grouped(_ albums: [PlexAlbum], matching query: String) -> [ArtistGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        var order: [String] = []
        var byArtist: [String: [PlexAlbum]] = [:]
        for album in albums {
            let key = album.parentRatingKey ?? album.parentTitle ?? album.ratingKey
            if byArtist[key] == nil { order.append(key) }
            byArtist[key, default: []].append(album)
        }

        return order.compactMap { key in
            let albums = byArtist[key] ?? []
            let name = albums.first?.parentTitle ?? "Unknown Artist"
            guard !needle.isEmpty else {
                return ArtistGroup(id: key, name: name, albums: newestFirst(albums))
            }
            if name.lowercased().contains(needle) {
                return ArtistGroup(id: key, name: name, albums: newestFirst(albums))
            }
            let matches = albums.filter { $0.title.lowercased().contains(needle) }
            return matches.isEmpty
                ? nil
                : ArtistGroup(id: key, name: name, albums: newestFirst(matches))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Newest release first. Albums the server has no year for sort last rather
    /// than to the top, which is where a zero default would put them.
    private static func newestFirst(_ albums: [PlexAlbum]) -> [PlexAlbum] {
        albums.sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
