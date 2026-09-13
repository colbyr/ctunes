import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the search page. `LibraryView`
/// pushes it when the search pill opens and pops it when the pill closes.
struct SearchRoute: Hashable {}

/// The section as the browse root loaded it, shared with the search page
/// so opening search never fetches the library a second time. The root
/// writes it on every load; the search page only reads.
@MainActor @Observable
final class LibraryCatalog {
    var albums: [PlexAlbum] = []
    var artists: [PlexArtist] = []
    var rotation: Rotation = .none
    var loaded = false

    /// Back to nothing, for a library switch.
    func reset() {
        albums = []
        artists = []
        rotation = .none
        loaded = false
    }
}

/// What was opened from search, newest first, per server, kept in
/// `UserDefaults`. A track is stored whole so it can play again later.
@MainActor @Observable
final class RecentSearches {
    private(set) var items: [SearchHit] = []
    @ObservationIgnored private var key = ""
    private static let limit = 20

    func load(server: String) {
        key = "recentSearches.\(server)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SearchHit].self, from: data)
        else { items = []; return }
        items = saved
    }

    /// To the front, once.
    func add(_ hit: SearchHit) {
        items.removeAll { $0.id == hit.id }
        items.insert(hit, at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        guard !key.isEmpty, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The search page: what was opened from here before while the field is
/// empty, otherwise names to finish the query with and one ranked list of
/// artists, albums and songs. Artists and albums are matched on the phone
/// from the catalog; songs are asked of the server as the query settles.
struct SearchView: View {
    let model: AppModel
    let section: PlexSection
    let catalog: LibraryCatalog
    @Binding var query: String
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying

    /// The server's tracks for `trackQuery`, which lags the field by the
    /// debounce and the round trip; until it catches up the list is
    /// artists and albums alone.
    @State private var tracks: [PlexTrack] = []
    @State private var trackQuery = ""
    @State private var recents = RecentSearches()

    private var needle: String { LibrarySearch.needle(query) }
    private var offline: Bool { model.library?.isOffline ?? false }
    private var hidden: VetoSet { model.roster.hidden }
    private var hits: [SearchHit] {
        LibrarySearch.hits(
            artists: catalog.artists, albums: catalog.albums,
            tracks: trackQuery == needle ? tracks : [],
            playlists: model.playlists,
            query: needle, hiding: hidden
        )
    }
    private var completions: [String] {
        LibrarySearch.completions(artists: catalog.artists, albums: catalog.albums, query: needle, hiding: hidden)
    }
    /// The server has answered for what is in the field.
    private var settled: Bool { trackQuery == needle }

    private static let margin: CGFloat = 16

    var body: some View {
        let hits = hits
        let completions = completions
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if needle.isEmpty {
                    if !recents.items.isEmpty {
                        HStack {
                            AlbumGroupHeader(name: "Recently Searched")
                            Spacer()
                            Button("Clear") { recents.clear() }
                                .font(.body)
                                .foregroundStyle(Color.accentText)
                        }
                        .padding(.init(top: 8, leading: Self.margin, bottom: 8, trailing: Self.margin))
                        hairline
                        BrowseList(items: recents.items) { row($0) }
                            .padding(.horizontal, Self.margin)
                    }
                } else {
                    ForEach(completions, id: \.self) { name in
                        Button { query = name } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(highlighted(name))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search for \(name)")
                        .padding(.horizontal, Self.margin)
                        hairline
                    }
                    BrowseList(items: hits) { row($0) }
                        .padding(.horizontal, Self.margin)
                        .padding(.top, completions.isEmpty ? 4 : 8)
                }
            }
        }
        .parchment()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.immediately)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay {
            if needle.isEmpty && recents.items.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                       description: Text("Artists, albums, playlists and songs."))
            } else if !needle.isEmpty && settled && hits.isEmpty && completions.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .task(id: model.library?.serverIdentifier) {
            recents.load(server: model.library?.serverIdentifier ?? "")
        }
        // A short settle so a fast typist doesn't send a request per
        // key; the artists and albums above answer at once regardless.
        // Keyed on the generation too, so a search opened on the snapshot
        // while the server was still being found asks again once it is.
        .task(id: TrackFetch(needle: needle, generation: model.libraryGeneration)) {
            guard !needle.isEmpty else {
                tracks = []
                trackQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let library = model.library else { return }
            do {
                let found = try await library.searchTracks(inSection: section.key, query: needle)
                guard !Task.isCancelled else { return }
                tracks = found
                trackQuery = needle
            } catch {
                guard !Task.isCancelled else { return }
                await model.connectionLost(error)
                tracks = []
                trackQuery = needle
            }
        }
    }

    /// What the track fetch is keyed on.
    private struct TrackFetch: Hashable {
        let needle: String
        let generation: Int
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.divider)
            .frame(height: 1)
            .padding(.leading, Self.margin)
    }

    /// The name with the part the query matched in ink and the rest
    /// muted, the way a search field's suggestions read.
    private func highlighted(_ name: String) -> AttributedString {
        var text = AttributedString(name)
        text.foregroundColor = .secondary
        if let match = name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]),
           let range = Range(match, in: text) {
            text[range].foregroundColor = .primary
        }
        return text
    }

    /// One result or recent as a browse row: a portrait for an artist, a
    /// cover for an album or a song, and the line under the name saying
    /// which it is. The `···` and the long press open the item's own menu.
    @ViewBuilder private func row(_ hit: SearchHit) -> some View {
        switch hit {
        case .artist(let artist):
            BrowseRow(
                url: model.library?.artworkURL(artist.thumb),
                round: true,
                title: artist.title,
                subtitle: "Artist",
                download: model.downloads.state(artist: artist.ratingKey)
            ) {
                recents.add(hit)
                path.append(ArtistRoute(ratingKey: artist.ratingKey, title: artist.title))
            } menu: {
                ArtistMenu(model: model, ratingKey: artist.ratingKey, title: artist.title)
            }
        case .album(let album):
            BrowseRow(
                url: model.library?.artworkURL(album.thumb),
                title: album.title,
                subtitle: Self.subtitle("Album", album.parentTitle),
                download: model.downloads.state(album),
                dimmed: offline && !model.downloads.hasDownloads(album)
            ) {
                recents.add(hit)
                path.append(album)
            } menu: {
                AlbumMenu(model: model, album: album)
            }
        case .playlist(let playlist):
            BrowseRow(
                url: model.library?.artworkURL(playlist.composite),
                placeholder: "music.note.list",
                title: playlist.title,
                subtitle: "Playlist · \(playlist.subtitle)",
                download: model.downloads.state(playlist),
                dimmed: offline && !model.downloads.hasDownloads(playlist)
            ) {
                recents.add(hit)
                path.append(playlist)
            } menu: {
                PlaylistMenu(model: model, playlist: playlist)
            }
        case .track(let track):
            let downloaded = model.downloads.isDownloaded(track)
            let downloading = !downloaded && model.downloads.isDownloading(track)
            BrowseRow(
                url: model.library?.artworkURL(track.thumb),
                title: track.title,
                subtitle: Self.subtitle("Song", track.trackArtist ?? track.grandparentTitle),
                download: downloaded ? .complete(undownloadable: 0)
                    : downloading ? .downloading(done: 0, total: 1, stalled: false) : .none,
                dimmed: offline && !model.downloads.isAvailable(track)
            ) {
                recents.add(hit)
                play(track)
            } menu: {
                TrackMenu(model: model, track: track, placement: .list(siblings: [track]))
            }
        }
    }

    /// "Album · The Strokes"; just the kind with no name to follow it.
    private static func subtitle(_ kind: String, _ name: String?) -> String {
        guard let name, !name.isEmpty else { return kind }
        return "\(kind) · \(name)"
    }

    /// Plays the song's album from that song, the tracks the active
    /// listeners hear inside the album; the song alone when the album
    /// can't be fetched. Offline, only songs with a file play.
    private func play(_ track: PlexTrack) {
        guard let library = model.library else { return }
        guard !offline || model.downloads.isAvailable(track) else { return }
        Task {
            var siblings = [track]
            if let key = track.parentRatingKey,
               let fetched = try? await library.tracks(inAlbum: key), !fetched.isEmpty {
                siblings = fetched
                if let album = track.album {
                    await model.rememberTracks(fetched, inAlbum: album)
                }
            }
            let hidden = model.roster.hidden
            let playable = siblings.filter {
                $0.id == track.id
                    || (!hidden.hides($0, within: .album) && (!offline || model.downloads.isAvailable($0)))
            }
            let start = playable.firstIndex { $0.id == track.id } ?? 0
            player.play(playable, startingAt: start, library: library)
            nowPlaying.isShown = true
        }
    }
}
