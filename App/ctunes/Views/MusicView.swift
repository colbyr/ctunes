import PlexKit
import SwiftUI

/// Browse root: every album in the library, or every artist, sorted,
/// grouped and laid out however the arrange button last left it. The
/// floating search pill opens the search page over it.
struct MusicView: View {
    let model: AppModel
    let section: PlexSection
    /// The albums and artists, loaded here and shared with the search page.
    let catalog: LibraryCatalog
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player

    private var albums: [PlexAlbum] { catalog.albums }
    /// Every artist in the section, for the Artists subject: the portraits
    /// and the artists' own play dates, which the albums don't carry.
    private var libraryArtists: [PlexArtist] { catalog.artists }
    /// Scored once when the plays land; `.none` before then or when the
    /// request fails, which leaves On Rotation on the server's play counts.
    private var rotation: Rotation { catalog.rotation }
    private var loaded: Bool { catalog.loaded }
    /// Fetched with the albums so the favorites shortcut can say how many
    /// tracks it would play; nil until the request lands.
    private var favorites: [PlexTrack]? { catalog.favorites }
    /// The tracks of every playlist a shortcut plays, keyed by the
    /// playlist, so the card can count what the listeners leave and
    /// stay off the screen when that is nothing. Fetched beside the
    /// albums and again when the shortcuts change.
    @State private var playlistTracks: [String: [PlexTrack]] = [:]
    /// The shortcut whose tracks are being fetched, for its spinner.
    @State private var loadingShortcut: SavedMix.ID?
    @State private var showingListeners = false
    @State private var showingSettings = false
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("albumView") private var view: AlbumView = .mostPlayed
    @AppStorage("albumDownloadedOnly") private var downloadedOnly = false
    @AppStorage("browseSubject") private var subject: BrowseSubject = .albums
    @AppStorage("browseLayout") private var layout: BrowseLayout = .grid

    private var offline: Bool { model.state == .offline }
    private var hidden: VetoSet { model.roster.hidden }
    /// Filtered before the pure grouping and search, so those stay pure.
    /// Anything with a file to play, so an album still downloading shows.
    private var browsable: [PlexAlbum] {
        downloadedOnly ? albums.filter { model.downloads.hasDownloads($0) } : albums
    }
    private var groups: [AlbumGroup] {
        AlbumBrowse.groups(browsable, view: view, hiding: hidden, rotation: rotation)
    }
    /// The Artists subject's list. Under Downloaded only, the artists with
    /// a downloaded album, read off the album list rather than rolling up
    /// every artist's state.
    private var browsableArtists: [PlexArtist] {
        guard downloadedOnly else { return libraryArtists }
        let downloaded = Set(browsable.map(\.artistKey))
        return libraryArtists.filter { downloaded.contains($0.ratingKey) }
    }
    private var artistGroups: [ArtistGroup] {
        AlbumBrowse.groups(browsableArtists, view: view, hiding: hidden, rotation: rotation)
    }
    /// How many albums each artist has in the section, for the line under
    /// their name.
    private var albumCounts: [String: Int] {
        albums.reduce(into: [:]) { $0[$1.artistKey, default: 0] += 1 }
    }
    /// Every artist in the library, for the listeners sheet.
    private var artists: [AlbumGroup] {
        AlbumBrowse.groups(albums, view: .artist)
    }
    /// The Playlists subject's list, the model's, in the view's order.
    /// Under Downloaded only, the playlists with a saved item on disk,
    /// which leaves out any never opened.
    private var playlists: [PlexPlaylist] {
        let all = model.playlists
        return view.sorted(downloadedOnly ? all.filter { model.downloads.hasDownloads($0) } : all)
    }
    /// Counted over this section's albums, so a veto from another
    /// section doesn't count here. Browsing artists, only the artists;
    /// playlists are not veto targets, so nothing there.
    private var hiddenCount: HiddenCount {
        switch subject {
        case .albums: .over(albums, hidden: hidden)
        case .artists: HiddenCount(artists: libraryArtists.filter { hidden.artists.contains($0.ratingKey) }.count)
        case .playlists: HiddenCount()
        }
    }
    /// Whether the browser has nothing to show under the filter.
    private var filteredOut: Bool {
        switch subject {
        case .albums: groups.isEmpty
        case .artists: artistGroups.isEmpty
        case .playlists: playlists.isEmpty && !showsFavorites
        }
    }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMinimum), spacing: 12, alignment: .top)]
    }

    /// Tiles push onto the path by hand: a NavigationLink in a List row makes
    /// the whole row a link too, so one tap pushed two albums and back landed
    /// on the wrong one.
    @ViewBuilder private func albumItems(_ albums: [PlexAlbum], showArtist: Bool) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(albums) { album in
                    Button { path.append(album) } label: {
                        AlbumTile(model: model, album: album, showArtist: showArtist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumMenu(model: model, album: album) }
                }
            }
        case .list:
            BrowseList(items: albums) { album in
                AlbumRow(model: model, album: album, showArtist: showArtist) { path.append(album) } menu: {
                    AlbumMenu(model: model, album: album)
                }
            }
        }
    }

    @ViewBuilder private func artistItems(_ artists: [PlexArtist]) -> some View {
        let counts = albumCounts
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(artists) { artist in
                    Button { path.append(ArtistRoute(ratingKey: artist.ratingKey, title: artist.title)) } label: {
                        ArtistTile(model: model, artist: artist, subtitle: Self.albumCount(counts[artist.ratingKey]))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ArtistMenu(model: model, ratingKey: artist.ratingKey, title: artist.title) }
                }
            }
        case .list:
            BrowseList(items: artists) { artist in
                ArtistRow(model: model, artist: artist, subtitle: Self.albumCount(counts[artist.ratingKey])) {
                    path.append(ArtistRoute(ratingKey: artist.ratingKey, title: artist.title))
                } menu: {
                    ArtistMenu(model: model, ratingKey: artist.ratingKey, title: artist.title)
                }
            }
        }
    }

    /// "12 albums"; nil for an artist with none in the section.
    private static func albumCount(_ count: Int?) -> String? {
        count.map { "\($0) album\($0 == 1 ? "" : "s")" }
    }

    /// The favorites lead the playlists, as on the playlists page.
    private var showsFavorites: Bool {
        !downloadedOnly || model.isFavoritesPinned
    }

    @ViewBuilder private func playlistItems(_ playlists: [PlexPlaylist]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if showsFavorites {
                    Button { path.append(FavoritesRoute()) } label: {
                        FavoritesTile(count: favorites?.count)
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
                FavoritesRow(count: favorites?.count) { path.append(FavoritesRoute()) }
                Rectangle()
                    .fill(Color.divider)
                    .frame(height: 1)
                    .padding(.leading, BrowseRow<EmptyView, EmptyView>.artSize + 12)
            }
            BrowseList(items: playlists) { playlist in
                PlaylistRow(model: model, playlist: playlist) { path.append(playlist) } menu: {
                    PlaylistMenu(model: model, playlist: playlist)
                }
            }
        }
    }

    /// The group headings and their items, either subject. Under the
    /// Artists view an album heading is the artist, and opens their page.
    @ViewBuilder private var sections: some View {
        switch subject {
        case .albums:
            ForEach(groups) { group in
                Section {
                    albumItems(group.albums, showArtist: view != .artist)
                        .padding(.init(top: group.name.isEmpty ? 14 : 2, leading: Self.margin, bottom: 0, trailing: Self.margin))
                } header: {
                    if !group.name.isEmpty {
                        if view == .artist, let key = group.albums.first?.parentRatingKey {
                            Button { path.append(ArtistRoute(ratingKey: key, title: group.name)) } label: {
                                HStack(spacing: 6) {
                                    AlbumGroupHeader(group: group)
                                    Image(systemName: "chevron.right")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(group.name)")
                            .contextMenu { ArtistMenu(model: model, ratingKey: key, title: group.name) }
                            .padding(.leading, Self.margin)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        } else {
                            AlbumGroupHeader(group: group)
                                .padding(.leading, Self.margin)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                    }
                }
            }
        case .artists:
            ForEach(artistGroups) { group in
                Section {
                    artistItems(group.artists)
                        .padding(.init(top: group.name.isEmpty ? 14 : 2, leading: Self.margin, bottom: 0, trailing: Self.margin))
                } header: {
                    if !group.name.isEmpty {
                        AlbumGroupHeader(name: group.name)
                            .padding(.leading, Self.margin)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                    }
                }
            }
        case .playlists:
            // One nameless section: every sort over playlists is flat.
            playlistItems(playlists)
                .padding(.init(top: 14, leading: Self.margin, bottom: 0, trailing: Self.margin))
        }
    }

    /// Matches the nav bar's large title and the bottom pills.
    private static let margin: CGFloat = 16
    /// Three across on a phone; on an iPad the same minimum gave nine tiny
    /// tiles, so the floor rises to keep the covers legible. 180 rather than 150:
    /// on a Mac window the smaller floor still packed six across, and the
    /// covers read as thumbnails rather than art.
    private var tileMinimum: CGFloat { sizeClass == .regular ? 180 : 100 }
    /// The screen's width, for the hero cards' layout.
    @State private var width: CGFloat = 0
    /// Two shortcut cards across need about 400pt each before a title
    /// like "Mix Albums Bon Jovi" and its count stop wrapping.
    private static let heroRowMinimum: CGFloat = 880

    @State private var scrollPosition = ScrollPosition()

    /// The mix builder and the playlists page, side by side.
    @ViewBuilder private var heroTiles: some View {
        HeroTile(title: "Mix Builder",systemImage: "square.stack", accent: .mix) { path.append(MixRoute()) }
        HeroTile(title: "Playlists", systemImage: "music.note.list", accent: .playlist) { path.append(PlaylistsRoute()) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if offline {
                    OfflineBanner(reconnecting: model.reconnecting) {
                        Task { await model.reconnect(force: true) }
                    }
                    .padding(.init(top: 8, leading: Self.margin, bottom: 4, trailing: Self.margin))
                }
                // The two half-width tiles, then the shortcuts, each a
                // full-width card on a phone and two across when the
                // screen has the width, where one is mostly empty. By
                // measured width, not size class: beside the Now Playing
                // column, or in a small Mac window, a "regular" stack can
                // be 600pt, where two across wraps a title one word per
                // line.
                VStack(spacing: 12) {
                    HStack(spacing: 12) { heroTiles }
                    let shown = visibleShortcuts
                    if !shown.isEmpty {
                        let columns = width >= Self.heroRowMinimum ? 2 : 1
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                            ForEach(shown) { mix in
                                ShortcutCard(model: model, mix: mix, subtitle: subtitle(for: mix),
                                             loading: loadingShortcut == mix.id) {
                                    play(mix)
                                } open: {
                                    open(mix)
                                } edit: {
                                    path.append(MixRoute(mixID: mix.id))
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .animation(.snappy, value: shown.map(\.id))
                    }
                }
                .padding(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                // The browser starts here: a rule, then the chips with the
                // arrange button, then the hidden-artist line when any are.
                Rectangle()
                    .fill(Color.divider)
                    .frame(height: 1)
                    .padding(.init(top: 8, leading: Self.margin, bottom: 0, trailing: Self.margin))
                AlbumBrowserControls(model: model, artists: artists, view: $view, layout: $layout,
                                     scope: subject.scope, subject: $subject, downloadedOnly: $downloadedOnly)
                    .padding(.top, 16)
                HiddenLine(model: model, count: hiddenCount)
                    .padding(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                // In the stack rather than an overlay, so it sits under the
                // cards and the controls instead of over them.
                if loaded, albums.isEmpty {
                    ContentUnavailableView("No albums", systemImage: "square.stack")
                        .frame(maxWidth: .infinity)
                        .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                } else if loaded, filteredOut, downloadedOnly {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Turn off Downloaded only to see the whole library."))
                        .frame(maxWidth: .infinity)
                        .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                } else if loaded, subject == .playlists, model.playlists.isEmpty, !showsFavorites {
                    ContentUnavailableView {
                        Label("No playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Make one from any track, album or artist's menu.")
                    } actions: {
                        if !offline {
                            Button("New Playlist") { navigator.composing = [] }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                }
                sections
            }
        }
        .parchment()
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Explicit so every screen fades the same way. `.hard` kept the
        // collapsed title crisper over artwork, but on iOS 27 it paints its
        // backdrop at rest too, leaving a line under the large title.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.immediately)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            }
        }
        .navigationTitle("Tunes")
        .toolbar {
            // A playlist with nothing in it yet, named here; online only,
            // like every playlist write.
            if subject == .playlists, !offline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Playlist", systemImage: "plus") { navigator.composing = [] }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        // Keyed on the generation so going offline, or coming back, reloads
        // from whichever library is current.
        .task(id: model.libraryGeneration) {
            await load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] != nil {
                showingListeners = true
            }
            if ProcessInfo.processInfo.environment["CTUNES_DEV_SETTINGS"] != nil {
                showingSettings = true
            }
            if let y = ProcessInfo.processInfo.environment["CTUNES_DEV_SCROLL"].flatMap(Double.init) {
                // Let the grid lay out, then scroll so the collapsed
                // title sits over artwork.
                try? await Task.sleep(for: .seconds(1))
                scrollPosition.scrollTo(y: y)
            }
            #endif
        }
        .refreshable { await load() }
        // A playlist shortcut added in Settings needs its tracks counted
        // too; keyed on the playlists the shortcuts name, not the list
        // itself, so restyling one doesn't refetch.
        .task(id: PlaylistShortcutsKey(keys: playlistShortcutKeys, generation: model.libraryGeneration)) {
            await loadPlaylistTracks()
        }
        // Handed the environment explicitly, like the Now Playing cover:
        // on the Mac a sheet's hosting controller is built without the
        // inherited environment and Settings' `@Environment(AudioPlayer.self)`
        // trapped while its sign-out dialog was evaluated.
        .sheet(isPresented: $showingListeners) {
            ListenersSheet(model: model, artists: artists)
                .environment(player)
                .environment(nowPlaying)
                .environment(navigator)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model, artists: artists)
                .environment(player)
                .environment(nowPlaying)
                .environment(navigator)
        }
    }

    /// "32 tracks for you & Laura"; just the count with no listeners set up,
    /// just the listeners until the count arrives, nothing with neither.
    /// The fetch: on appear, on a library swap, and on pull to refresh.
    private func load() async {
        guard let library = model.library else { return }
        var history: [PlayHistoryEntry] = []
        do {
            async let favoriteTracks = library.favoriteTracks(inSection: section.key)
            // Optional: the grid falls back to play counts without it.
            async let plays = library.playHistory(inSection: section.key, since: .now - Rotation.window)
            // Optional too: the Artists subject is empty until it lands,
            // and the Playlists subject keeps the last list.
            async let artistList = library.artists(inSection: section.key)
            async let playlistList: () = model.loadPlaylists()
            catalog.albums = try await library.albums(inSection: section.key)
            catalog.loaded = true
            history = (try? await plays) ?? []
            catalog.rotation = Rotation(history: history, albums: albums)
            catalog.artists = (try? await artistList) ?? []
            catalog.favorites = try? await favoriteTracks
            await playlistList
        } catch {
            await model.connectionLost(error)
            catalog.loaded = true
            return
        }
        if !library.isOffline {
            await model.snapshot(albums: albums, favorites: favorites ?? [], history: history)
        }
    }

    /// The playlists the shortcuts play, in shortcut order.
    private var playlistShortcutKeys: [String] {
        var keys: [String] = []
        for mix in model.shortcuts {
            for case .playlist(let key, _, _) in mix.picks where !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    private struct PlaylistShortcutsKey: Hashable {
        let keys: [String]
        let generation: Int
    }

    /// The items of every playlist a shortcut plays, concurrently and
    /// each optional: a playlist that fails to load keeps its card, with
    /// the list's own count under it.
    private func loadPlaylistTracks() async {
        guard let library = model.library else { return }
        let keys = playlistShortcutKeys
        playlistTracks = playlistTracks.filter { keys.contains($0.key) }
        let missing = keys.filter { playlistTracks[$0] == nil }
        let fetched = await withTaskGroup(of: (String, [PlexTrack]?).self) { group in
            for key in missing {
                group.addTask { (key, try? await library.items(inPlaylist: key).map(\.track)) }
            }
            var all: [String: [PlexTrack]] = [:]
            for await (key, tracks) in group {
                if let tracks { all[key] = tracks }
            }
            return all
        }
        playlistTracks.merge(fetched) { _, new in new }
    }

    /// The shortcuts with something left to play for the people
    /// listening. One is dropped when every pick is hidden: an artist or
    /// album by its own or a wider veto, an artist with every album
    /// vetoed, the favorites or a playlist once their tracks are known
    /// and none survive. Not knowing keeps the card, and a mix of the
    /// whole library is never hidden.
    private var visibleShortcuts: [SavedMix] {
        model.shortcuts.filter { $0.picks.isEmpty || !$0.picks.allSatisfy(isHidden) }
    }

    private func isHidden(_ pick: MixPick) -> Bool {
        if pick.isHidden(by: hidden) { return true }
        switch pick {
        case .favorites:
            guard let favorites, !favorites.isEmpty else { return false }
            return !favorites.contains { !hidden.hides($0) }
        case .playlist(let key, _, _):
            guard let tracks = playlistTracks[key], !tracks.isEmpty else { return false }
            return !tracks.contains { !hidden.hides($0) }
        case .artist(let key, _, _):
            let theirs = albums.filter { $0.artistKey == key }
            return !theirs.isEmpty && !theirs.contains { !hidden.hides($0) }
        case .album:
            return false
        }
    }

    /// The line under a card. For one pick, what it would play for the
    /// people listening ("32 tracks for you & Laura"): just the count with
    /// no listeners set up, just the listeners until the count arrives,
    /// nothing with neither; an album says its artist and year instead,
    /// since its tracks aren't counted here. For a real mix, what is in
    /// it, with the picks the listeners hide left out.
    private func subtitle(for mix: SavedMix) -> String? {
        guard mix.picks.count == 1 else {
            let shown = mix.picks.filter { !isHidden($0) }
            return SavedMix(name: "", picks: shown, style: mix.style).caption
        }
        let count: String?
        switch mix.picks[0] {
        case .favorites:
            count = favorites.map { PlexPlaylist.trackCount(allowed($0).count) }
        case .playlist(let key, _, _):
            if let tracks = playlistTracks[key] {
                count = PlexPlaylist.trackCount(allowed(tracks).count)
            } else if let listed = model.playlists.first(where: { $0.ratingKey == key }), !listed.smart {
                count = PlexPlaylist.trackCount(listed.leafCount ?? 0)
            } else {
                count = nil
            }
        case .artist(let key, _, _):
            count = loaded ? Self.albumCount(albums.filter { $0.artistKey == key && !hidden.hides($0) }.count) : nil
        case .album(let key, _, _, let artist, _):
            let album = albums.first { $0.ratingKey == key }
            let line = [album?.parentTitle ?? artist, album?.year.map(String.init)].compactMap { $0 }
            return line.isEmpty ? nil : line.joined(separator: " · ")
        }
        let names = model.roster.activeNames
        let who = model.roster.listeners.count <= 1
            ? nil
            : "for " + (names.isEmpty ? "no one" : ListenerRoster.joinNames(names))
        let parts = [count, who].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Offline, also only tracks with a file: an unplayable track must
    /// never enter the queue.
    private func allowed(_ tracks: [PlexTrack]) -> [PlexTrack] {
        tracks.filter {
            !hidden.hides($0) && (!offline || model.downloads.isAvailable($0))
        }
    }

    /// Fetched fresh rather than from the count's copy: hearts and
    /// playlists may have changed since the screen loaded. A play of the
    /// favorites refreshes their count too.
    private func play(_ mix: SavedMix) {
        guard loadingShortcut == nil else { return }
        loadingShortcut = mix.id
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        Task {
            defer { loadingShortcut = nil }
            await actions.play(mix)
            if mix.picks.contains(.favorites), let library = model.library,
               let fresh = try? await library.favoriteTracks(inSection: section.key) {
                catalog.favorites = fresh
            }
        }
    }

    /// The chevron: one pick opens the thing itself; a mix of several,
    /// or of the whole library, opens the builder on its picks.
    private func open(_ mix: SavedMix) {
        guard mix.picks.count == 1 else { return path.append(MixRoute(mixID: mix.id)) }
        switch mix.picks[0] {
        case .favorites:
            path.append(FavoritesRoute())
        case .playlist(let key, let title, _):
            path.append(model.playlists.first { $0.ratingKey == key } ?? PlexPlaylist(ratingKey: key, title: title))
        case .artist(let key, let title, _):
            path.append(ArtistRoute(ratingKey: key, title: title))
        case .album(let key, let title, let artistKey, let artist, let thumb):
            path.append(albums.first { $0.ratingKey == key }
                ?? PlexAlbum(ratingKey: key, title: title, parentRatingKey: artistKey, parentTitle: artist, year: nil, thumb: thumb))
        }
    }
}

/// First row of the browse root while the server is away. Same chrome as
/// the shuffle card, so it reads as part of the page rather than an alert.
private struct OfflineBanner: View {
    let reconnecting: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "network.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.fill.tertiary, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline").font(.headline)
                Text("Playing downloaded music").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if reconnecting {
                ProgressView()
            } else {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 24)
    }
}

/// Half-width entry to the mix builder or the playlists page, sharing the
/// hero card's chrome, each in its own color so the two read apart at a
/// glance.
private struct HeroTile: View {
    let title: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.16), in: .circle)
                // Half a phone's width beside the chevron is tight for
                // "Mix Builder": one line, shrunk before it would truncate.
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                // A page to go to, not an action: the favorites card's
                // chevron, a size down to leave the title its width.
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard()
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}
