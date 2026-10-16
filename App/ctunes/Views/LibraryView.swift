import PlexKit
import SwiftUI

/// Browse root. Shows the chosen music library, or asks which one to use when
/// the server has more than one and nothing has been picked yet.
struct LibraryView: View {
    let model: AppModel
    @State private var path = NavigationPath()
    @State private var query = ""
    /// The search pill is open. On the root and the deeper pages that
    /// means the search page is on top of the stack; under a mix builder
    /// the pill filters the builder's pool instead.
    @State private var searching = false
    /// How deep the search page sits in the stack, nil while it isn't
    /// there. The page follows the pill: opening the pill pushes it,
    /// closing pops it, and a page pushed over it folds the pill.
    @State private var searchDepth: Int?
    /// The section's albums and artists, loaded by the browse root and
    /// read by the search page.
    let catalog: LibraryCatalog
    /// The `ctunes://` route a widget asked for, taken here since the
    /// URL can land before this stack exists.
    let links: DeepLinks
    /// True while a mix builder is on top of the stack; the search pill then
    /// filters the builder's pool instead of opening the search page.
    @State private var buildingMix = false
    @State private var nowPlaying = NowPlayingPresentation()
    /// Written by the bottom bar, read by the mix builder, whose search
    /// results would otherwise sit under the keyboard.
    @State private var keyboard = KeyboardInset()
    /// Routes and notices posted by the item menus, which sit on screens
    /// with no path of their own.
    @State private var navigator = LibraryNavigator()
    /// The name field of the New Playlist and Rename alerts, and what
    /// they act on, captured when the request lands so the alert's
    /// action still has it after the presentation clears the request.
    @State private var playlistName = ""
    @State private var composingTracks: [PlexTrack] = []
    @State private var editingPlaylist: PlexPlaylist?
    @Environment(AudioPlayer.self) private var player
    /// Compact is a phone, where Now Playing covers the screen with its
    /// header scrolling; regular but too narrow for the column (an iPad in
    /// portrait, a small Mac window) covers it with a title bar instead.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The window's width, measured rather than read off the size class:
    /// see `NowPlayingPresentation.isColumn`.
    @State private var width: CGFloat = 0

    /// Narrower than this and Now Playing is a presentation: the phone
    /// layout. An iPad is a column in landscape and a cover in portrait,
    /// where a column would leave two tiles across.
    private static let columnThreshold: CGFloat = 960
    /// A window wider than it is tall takes the column from here. An
    /// iPhone Duo open in landscape is 951pt less the vertical bar's
    /// inset, about 850 usable, where two pages of 425 fit the browser's
    /// tiles two across; an 11" iPad's 834pt portrait is taller than wide
    /// and keeps the cover.
    private static let wideColumnThreshold: CGFloat = 800
    /// The window's height, beside the width, for the wide rule.
    @State private var height: CGFloat = 0
    /// Where a vertical fold runs, from the window's leading edge, on a
    /// device that has one (iOS 27.1 reports it flat as well as folded).
    /// The column ends there, so its edge is the crease: half the usable
    /// width stopped 50pt short of it, since the vertical bar's inset is
    /// all on the trailing side.
    @State private var foldX: CGFloat?
    /// Up to the fold where there is one, so the player is the left page
    /// and the browser the right; otherwise half the window, capped, so a
    /// wider window keeps the browser the bigger side.
    private var columnWidth: CGFloat {
        if let foldX { return foldX - 0.5 }
        return min(width / 2, 560)
    }

    /// What the host measures: the window's usable size and the fold.
    private struct Geometry: Equatable {
        var size: CGSize
        var foldX: CGFloat?
    }

    /// The cover while the window is narrow.
    private var presented: Binding<Bool> {
        Binding(
            get: { nowPlaying.isShown && !nowPlaying.isColumn },
            set: { nowPlaying.isShown = $0 }
        )
    }

    var body: some View {
        // Now Playing's one host: a leading column beside the stack in a
        // wide window, always there, and a presentation over the stack in
        // a narrow one. Not `.inspector`, which follows the size class: on
        // the Mac that only turns compact a hair above the window's minimum
        // width, so the column stayed however small the window got, and
        // its width was capped well under what a wide window can afford.
        // Leading, not trailing: on an iPhone Duo held open like a book
        // the fold runs down the middle, and the player reads as the left
        // page with the library on the right.
        HStack(spacing: 0) {
            if nowPlaying.isColumn {
                NowPlayingView(model: model, style: .column)
                    .frame(width: columnWidth)
                    .transition(.move(edge: .leading))
                Rectangle()
                    .fill(Color.divider)
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
            stack
        }
        // Chrome is ink, not amber: the back chevron, the toolbar buttons.
        // Amber is reserved for what acts, and those set it by hand.
        .tint(Color.ink)
        .animation(.snappy, value: nowPlaying.isColumn)
        .environment(nowPlaying)
        .environment(navigator)
        .environment(keyboard)
        // The cover is handed the observables by hand. When a Mac window
        // drags across the compact/regular boundary UIKit re-hosts the
        // open presentation, and that pass evaluates the content without
        // the environment it inherited from above: "No Observable object
        // of type AudioPlayer found", a trap, at 730pt every time.
        // On a phone it is a sheet, so dragging it down closes it the way
        // any sheet does; a regular width too narrow for the column gets
        // the cover, since a sheet there is a card floating mid-screen.
        .sheet(isPresented: sizeClass == .compact ? presented : .constant(false)) {
            NowPlayingView(model: model, style: .phone)
                .environment(player)
                .environment(nowPlaying)
                .environment(navigator)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: sizeClass == .compact ? .constant(false) : presented) {
            NowPlayingView(model: model, style: .fullScreen)
                .environment(player)
                .environment(nowPlaying)
                .environment(navigator)
        }
        // Crossing compact/regular would swap the sheet for the cover
        // under the user; close instead, as the column threshold does.
        .onChange(of: sizeClass) { _, _ in nowPlaying.isShown = false }
        // A route from a menu, or the artist tapped in Now Playing: the
        // cover has closed itself (or the column stays), and the page goes
        // onto the stack behind it.
        .onChange(of: links.route, initial: true) { _, route in
            guard let route else { return }
            navigator.open(route)
            links.route = nil
        }
        // The vertical bar's search item opens the pill the way its own
        // icon does.
        .onChange(of: navigator.searchRequested) { _, wanted in
            guard wanted else { return }
            navigator.searchRequested = false
            searching = true
        }
        .background {
            if #available(iOS 27.1, *) {
                VerticalBarProbe(navigator: navigator)
            }
        }
        .onChange(of: navigator.requested) { _, route in
            guard let route else { return }
            switch route {
            case .artist(let artist): path.append(artist)
            case .album(let album): path.append(album)
            case .playlist(let playlist): path.append(playlist)
            case .mix(let route): path.append(route)
            case .favorites: path.append(FavoritesRoute())
            }
            navigator.requested = nil
        }
        .alert(navigator.notice ?? "", isPresented: Binding(
            get: { navigator.notice != nil },
            set: { if !$0 { navigator.notice = nil } }
        )) {
            Button("OK") {}
        }
        // "New Playlist…" from any menu, or the root's plus: a name, then
        // the new playlist's page. Rename and Delete come the same way,
        // since the menus that offer them sit on tiles with no host.
        .onChange(of: navigator.composing) { _, tracks in
            guard let tracks else { return }
            composingTracks = tracks
            playlistName = ""
        }
        .onChange(of: navigator.renaming) { _, playlist in
            guard let playlist else { return }
            editingPlaylist = playlist
            playlistName = playlist.title
        }
        .onChange(of: navigator.deleting) { _, playlist in
            if let playlist { editingPlaylist = playlist }
        }
        .alert("New Playlist", isPresented: Binding(
            get: { navigator.composing != nil },
            set: { if !$0 { navigator.composing = nil } }
        )) {
            TextField("Name", text: $playlistName)
            Button("Create") {
                let title = playlistName.trimmingCharacters(in: .whitespaces)
                let tracks = composingTracks
                Task {
                    if let created = await model.createPlaylist(title: title, tracks: tracks) {
                        path.append(created)
                    } else {
                        navigator.notice = "Couldn't create the playlist."
                    }
                }
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = composingTracks.count
            Text(count == 0 ? "Add tracks from any track, album or artist's menu." : "Starts with \(PlexPlaylist.trackCount(count)).")
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { navigator.renaming != nil },
            set: { if !$0 { navigator.renaming = nil } }
        )) {
            TextField("Name", text: $playlistName)
            Button("Rename") {
                let title = playlistName.trimmingCharacters(in: .whitespaces)
                guard let playlist = editingPlaylist, title != playlist.title else { return }
                Task {
                    if await !model.rename(playlist, to: title) {
                        navigator.notice = "Couldn't rename \(playlist.title)."
                    }
                }
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(editingPlaylist?.title ?? "")”?",
            isPresented: Binding(
                get: { navigator.deleting != nil },
                set: { if !$0 { navigator.deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                guard let playlist = editingPlaylist else { return }
                Task {
                    if await !model.delete(playlist) {
                        navigator.notice = "Couldn't delete \(playlist.title)."
                    }
                }
            }
        } message: {
            Text("The playlist is removed from your Plex account. Nothing is removed from your library.")
        }
        .removeDownloadConfirmation(Bindable(navigator).removing)
        .onGeometryChange(for: Geometry.self) { proxy in
            var foldX: CGFloat?
            if #available(iOS 27.1, *) {
                // The fold as a division region, inactive while flat but
                // still placed; only one running top to bottom is a page
                // boundary, the horizontal one of the laptop pose isn't.
                let folds = proxy.reservedRegions(kind: .division, options: .includeInactive)
                foldX = folds.first { $0.frame.height > $0.frame.width }?.frame.midX
            }
            return Geometry(size: proxy.size, foldX: foldX)
        } action: { geometry in
            let size = geometry.size
            width = size.width
            height = size.height
            foldX = geometry.foldX
            let column = size.width >= Self.columnThreshold
                || (size.width > size.height && size.width >= Self.wideColumnThreshold)
            guard column != nowPlaying.isColumn else { return }
            nowPlaying.isColumn = column
            // Crossing either way closes the presentation: into the column
            // it is redundant, out of it the column is gone and the stack
            // should be what's left, not a cover over it.
            nowPlaying.isShown = false
        }
        // The search page goes wherever the pill opens, on top of the
        // root or of an album page, so back returns to what was there.
        // Reopening the pill over a page pushed from a result pops back
        // to the results; closing it takes the page away.
        .onChange(of: searching) { _, active in
            guard !buildingMix else { return }
            if active {
                if let depth = searchDepth {
                    if path.count > depth { path.removeLast(path.count - depth) }
                } else {
                    path.append(SearchRoute())
                    searchDepth = path.count
                }
            } else if let depth = searchDepth, path.count == depth {
                path.removeLast()
                searchDepth = nil
                query = ""
            }
        }
        // A page pushed over the search page folds the pill to its icon
        // and keeps the query, so back lands on the same results; popping
        // past the page (the back button on it) closes the search.
        .onChange(of: path.count) { _, count in
            guard let depth = searchDepth else { return }
            if count < depth {
                searchDepth = nil
                searching = false
                query = ""
            } else {
                searching = count == depth
            }
        }
        // A builder's query filters its pool only; popping back to the root
        // shouldn't leave the root showing results for it.
        .onChange(of: buildingMix) { _, building in
            if !building {
                query = ""
                searching = false
            }
        }
        .task {
            if let album = Self.developmentAlbum {
                path.append(album)
            }
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_ARTIST"], !raw.isEmpty {
                let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                path.append(ArtistRoute(ratingKey: parts[0], title: parts.count > 1 ? parts[1] : "Artist"))
            }
            // `artist` or `album` opens the builder on that pool.
            if let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX"],
               let kind = MixPickKind(rawValue: String(raw.prefix { $0 != ":" })) {
                let subject: BrowseSubject = switch kind {
                case .artist: .artists
                case .album: .albums
                case .playlist, .favorites: .playlists
                }
                UserDefaults.standard.set(subject.rawValue, forKey: "mixSubject")
                path.append(MixRoute())
            }
            if ProcessInfo.processInfo.environment["CTUNES_DEV_FAVORITES"] == "1" {
                path.append(FavoritesRoute())
            }
            // `list` switches the root to the Playlists subject; a
            // `ratingKey|title` pushes that playlist's page.
            if let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_PLAYLIST"], !raw.isEmpty {
                if raw == "list" {
                    UserDefaults.standard.set(BrowseSubject.playlists.rawValue, forKey: "browseSubject")
                } else {
                    let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                    path.append(PlexPlaylist(ratingKey: parts[0], title: parts.count > 1 ? parts[1] : "Playlist"))
                }
            }
            if let seed = ProcessInfo.processInfo.environment["CTUNES_DEV_SEARCH"], !seed.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                searching = true
                if seed != "1" { query = seed }
            }
            #endif
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            Group {
                if let section = model.selectedSection {
                    // Keyed on the section so switching libraries from
                    // Settings starts the screen over instead of leaving the
                    // old albums under the new title.
                    MusicView(model: model, section: section, catalog: catalog, path: $path)
                        .id(section.key)
                } else {
                    SectionPicker(model: model)
                }
            }
            // Declared at the stack root so a seeded path can reach it.
            .navigationDestination(for: PlexAlbum.self) { album in
                TracksView(model: model, album: album, path: $path)
            }
            .navigationDestination(for: ArtistRoute.self) { route in
                if let section = model.selectedSection {
                    ArtistView(model: model, section: section, route: route, path: $path)
                }
            }
            .navigationDestination(for: MixRoute.self) { route in
                if let section = model.selectedSection {
                    MixBuilderView(model: model, section: section, route: route, query: $query, building: $buildingMix)
                }
            }
            .navigationDestination(for: PlaylistsRoute.self) { _ in
                PlaylistsView(model: model, catalog: catalog, path: $path)
            }
            .navigationDestination(for: FavoritesRoute.self) { _ in
                if let section = model.selectedSection {
                    FavoritesView(model: model, section: section)
                }
            }
            .navigationDestination(for: PlexPlaylist.self) { playlist in
                PlaylistView(model: model, playlist: playlist)
            }
            .navigationDestination(for: SearchRoute.self) { _ in
                if let section = model.selectedSection {
                    SearchView(model: model, section: section, catalog: catalog, query: $query, path: $path)
                }
            }
        }
        // Attached to the stack, not to its root view: on the root view the
        // inset is replaced along with the content on every push, so the
        // mini player vanishes as soon as you navigate anywhere.
        .safeAreaInset(edge: .bottom) {
            BottomBar(model: model, query: $query, searching: $searching)
        }
        // The bar lifts itself from the keyboard's frame notification.
        // SwiftUI's own avoidance is applied to whichever screen is on top
        // when the keyboard rises, so a search opened from an album page
        // popped with the bar still under the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Debug-only deep link so the deeper screens can be driven in a
    /// simulator, where there's no way to tap through. Pushes onto the stack
    /// rather than replacing the root, so navigation behaves as it really does.
    static var developmentAlbum: PlexAlbum? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_ALBUM"],
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 3).map(String.init)
        return PlexAlbum(
            ratingKey: parts[0],
            title: parts.count > 1 ? parts[1] : "Album",
            parentRatingKey: parts.count > 3 ? parts[3] : nil,
            parentTitle: parts.count > 2 ? parts[2] : nil,
            year: nil,
            thumb: nil
        )
        #else
        return nil
        #endif
    }
}

private struct SectionPicker: View {
    let model: AppModel

    var body: some View {
        List(model.sections) { section in
            Button {
                model.selectSection(section)
            } label: {
                Label(section.title, systemImage: "music.note.list")
            }
        }
        .parchment()
        .navigationTitle("Choose a library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sign out") { Task { await model.signOut() } }
            }
        }
    }
}
