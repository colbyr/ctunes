import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the playlists page.
struct PlaylistsRoute: Hashable {}

/// Every playlist on the section as one list to keep: open one, start a
/// new one, rename or delete from its menu, delete with a swipe. The
/// root's Playlists subject browses the same list; this is where they are
/// managed. A `List` for the swipe: the rows are a fixed height, so the
/// Mac's resize recursion over width-dependent rows doesn't apply.
struct PlaylistsView: View {
    let model: AppModel
    @Binding var path: NavigationPath
    @Environment(LibraryNavigator.self) private var navigator
    @State private var loaded = false
    /// Its own sort, A to Z until arranged otherwise.
    @AppStorage("playlistsView") private var sort: AlbumView = .artist

    private var offline: Bool { model.library?.isOffline ?? false }

    private static let margin: CGFloat = 16

    var body: some View {
        let playlists = sort.sorted(model.playlists)
        List {
            ForEach(playlists) { playlist in
                PlaylistRow(model: model, playlist: playlist) { path.append(playlist) } menu: {
                    PlaylistMenu(model: model, playlist: playlist)
                }
                .listRowInsets(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin - 4))
                .listRowBackground(Color.clear)
                // Asks first, through the same prompt as the menu's
                // Delete; no destructive role, which would take the row
                // away before the answer.
                .swipeActions(edge: .trailing) {
                    if !offline, !playlist.smart {
                        Button { navigator.deleting = playlist } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(AlbumView.cases(in: .playlists), id: \.self) { Text($0.title(in: .playlists)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
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
