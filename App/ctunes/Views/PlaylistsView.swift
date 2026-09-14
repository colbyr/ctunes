import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the playlists page.
struct PlaylistsRoute: Hashable {}

/// Every playlist on the section, to keep: open one, start a new one,
/// rename or delete from its menu. The listener chips and the arrange
/// buttons sit over it as on the root, with its own sort and filter and
/// the app's layout. A `ScrollView`, not a `List`: the grid's tiles are
/// width-dependent, which recurses in a Mac window's live resize.
struct PlaylistsView: View {
    let model: AppModel
    /// The albums the root loaded, for the Listeners sheet's artist list.
    let catalog: LibraryCatalog
    @Binding var path: NavigationPath
    @Environment(LibraryNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var loaded = false
    /// Its own sort, A to Z until arranged otherwise.
    @AppStorage("playlistsView") private var sort: AlbumView = .artist
    @AppStorage("playlistsDownloadedOnly") private var downloadedOnly = false
    @AppStorage(BrowseLayout.key) private var layout: BrowseLayout = .grid

    private var offline: Bool { model.library?.isOffline ?? false }

    private static let margin: CGFloat = 16
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 100), spacing: 12, alignment: .top)]
    }

    private var playlists: [PlexPlaylist] {
        let all = model.playlists
        return sort.sorted(downloadedOnly ? all.filter { model.downloads.hasDownloads($0) } : all)
    }

    @ViewBuilder private func items(_ playlists: [PlexPlaylist]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(playlists) { playlist in
                    Button { path.append(playlist) } label: {
                        PlaylistTile(model: model, playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { PlaylistMenu(model: model, playlist: playlist) }
                }
            }
        case .list:
            BrowseList(items: playlists) { playlist in
                PlaylistRow(model: model, playlist: playlist) { path.append(playlist) } menu: {
                    PlaylistMenu(model: model, playlist: playlist)
                }
            }
        }
    }

    var body: some View {
        let playlists = playlists
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AlbumBrowserControls(model: model, artists: AlbumBrowse.groups(catalog.albums, view: .artist),
                                     view: $sort, layout: $layout, scope: .playlists, downloadedOnly: $downloadedOnly)
                    .padding(.top, 8)
                if loaded, !model.playlists.isEmpty, playlists.isEmpty, downloadedOnly {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Turn off Downloaded only to see every playlist."))
                        .frame(maxWidth: .infinity)
                        .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                }
                items(playlists)
                    .padding(.init(top: 14, leading: Self.margin, bottom: 0, trailing: Self.margin))
            }
        }
        .parchment()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.bottom, 84, for: .scrollContent)
        .animation(.snappy, value: playlists.map(\.id))
        .overlay {
            if model.playlists.isEmpty {
                if !loaded {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Make one here, or from any track, album or artist's menu.")
                    } actions: {
                        if !offline {
                            Button("New Playlist") { navigator.composing = [] }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationSubtitle(model.playlists.isEmpty ? "" : "\(playlists.count) playlist\(playlists.count == 1 ? "" : "s")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Online only, like every playlist write.
            if !offline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Playlist", systemImage: "plus") { navigator.composing = [] }
                }
            }
        }
        .task(id: model.libraryGeneration) {
            await model.loadPlaylists()
            loaded = true
        }
        .refreshable { await model.loadPlaylists() }
    }
}
