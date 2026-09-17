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

    /// The favorites lead the list under every sort: they are the one
    /// list here that isn't the server's, and the page should reach them
    /// whether or not a shortcut does. Under Downloaded only, only once
    /// they're pinned.
    private var showsFavorites: Bool {
        !downloadedOnly || model.isFavoritesPinned
    }

    @ViewBuilder private func items(_ playlists: [PlexPlaylist]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if showsFavorites {
                    Button { path.append(FavoritesRoute()) } label: {
                        FavoritesTile(count: catalog.favorites?.count)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(playlists) { playlist in
                    Button { path.append(playlist) } label: {
                        PlaylistTile(model: model, playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { PlaylistMenu(model: model, playlist: playlist) }
                }
            }
        case .list:
            if showsFavorites {
                FavoritesRow(count: catalog.favorites?.count) { path.append(FavoritesRoute()) }
                Rectangle()
                    .fill(Color.divider)
                    .frame(height: 1)
                    .padding(.leading, BrowseRow<EmptyView, EmptyView>.artSize + 12)
            }
            BrowseList(items: playlists) { playlist in
                PlaylistRow(model: model, playlist: playlist) { path.append(playlist) } menu: {
                    PlaylistMenu(model: model, playlist: playlist)
                }
                // The menu's Delete Playlist…, confirmed by the same host.
                // A smart playlist is the server's, so its swipe says why
                // there's no Delete. Writes are online only.
                .rowSwipe(offline ? nil : playlist.smart
                    ? RowSwipe(title: "Smart", systemImage: "gearshape.fill", tint: .gray) {
                        navigator.notice = PlexPlaylist.smartEditNotice
                    }
                    : RowSwipe(title: "Delete", systemImage: "trash", tint: .red, role: .destructive) {
                        navigator.deleting = playlist
                    })
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
                if loaded, !model.playlists.isEmpty, playlists.isEmpty, downloadedOnly, !showsFavorites {
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
            // With the favorites leading the list the page is never bare;
            // the hint waits for a filter that hides them too.
            if model.playlists.isEmpty {
                if !loaded {
                    ProgressView()
                } else if !showsFavorites {
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
