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
    /// Fetched with the albums so the shuffle card can say how many tracks
    /// it would play; nil until the request lands.
    @State private var favorites: [PlexTrack]?
    @State private var loadingFavorites = false
    @State private var noFavorites = false
    @State private var everyFavoriteHidden = false
    @State private var showingListeners = false
    @State private var showingSettings = false
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("albumView") private var view: AlbumView = .mostPlayed
    @AppStorage("albumDownloadedOnly") private var downloadedOnly = false
    @AppStorage("browseSubject") private var subject: BrowseSubject = .albums
    @AppStorage(BrowseLayout.key) private var layout: BrowseLayout = .grid

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
        case .playlists: playlists.isEmpty
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

    @ViewBuilder private func playlistItems(_ playlists: [PlexPlaylist]) -> some View {
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
    /// Three cards across need about 280pt each before the favorites
    /// title and its track count stop wrapping.
    private static let heroRowMinimum: CGFloat = 880

    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if offline {
                    OfflineBanner(reconnecting: model.reconnecting) {
                        Task { await model.reconnect(force: true) }
                    }
                    .padding(.init(top: 8, leading: Self.margin, bottom: 4, trailing: Self.margin))
                }
                // One row of three when the screen has the width for
                // it, where a full-width hero card is mostly empty;
                // otherwise the favorites card takes its own row. By
                // measured width, not size class: beside the Now
                // Playing column, or in a small Mac window, a "regular"
                // stack can be 600pt, where three across wraps the
                // favorites title one letter per line.
                Group {
                    if width >= Self.heroRowMinimum {
                        HStack(spacing: 12) {
                            MixTile(kind: .artist) { path.append(MixKind.artist) }
                            MixTile(kind: .album) { path.append(MixKind.album) }
                            ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites) { path.append(FavoritesRoute()) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                MixTile(kind: .artist) { path.append(MixKind.artist) }
                                MixTile(kind: .album) { path.append(MixKind.album) }
                            }
                            ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites) { path.append(FavoritesRoute()) }
                        }
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
                if loaded, !albums.isEmpty, filteredOut, downloadedOnly {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Turn off Downloaded only to see the whole library."))
                        .frame(maxWidth: .infinity)
                        .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                } else if loaded, subject == .playlists, model.playlists.isEmpty {
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
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
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
        .alert("No favorites yet", isPresented: $noFavorites) {
            Button("OK") {}
        } message: {
            Text("Tap ··· on a track, or the heart in Now Playing, to favorite it.")
        }
        .alert("Nothing to shuffle", isPresented: $everyFavoriteHidden) {
            Button("OK") {}
        } message: {
            Text("Every favorite is hidden for \(ListenerRoster.joinNames(model.roster.activeNames)).")
        }
        .sheet(isPresented: $showingListeners) {
            ListenersSheet(model: model, artists: artists)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model, artists: artists)
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
            favorites = try? await favoriteTracks
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

    private var favoritesSubtitle: String? {
        let names = model.roster.activeNames
        let who = model.roster.others.isEmpty
            ? nil
            : "for " + (names.isEmpty ? "no one" : names == ["you"] ? "just you" : ListenerRoster.joinNames(names))
        let count = favorites.map { allowed($0).count }
            .map { "\($0) track\($0 == 1 ? "" : "s")" }
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

    /// Every favorite track in the library, in a fresh random order each tap.
    /// Spread-shuffling once at enqueue time is all this needs; the player has
    /// no shuffle mode of its own.
    private func shuffleFavorites() {
        guard var library = model.library, !loadingFavorites else { return }
        loadingFavorites = true
        Task {
            defer { loadingFavorites = false }
            // Fetched fresh rather than reusing the count's copy: hearts may
            // have been toggled since the screen loaded.
            let fetched: [PlexTrack]
            do {
                fetched = try await library.favoriteTracks(inSection: section.key)
            } catch {
                // The address may be stale (Wi-Fi to cellular): once the
                // model has moved the library, one more go on the new one.
                guard await model.connectionLost(error), let current = model.library,
                      let again = try? await current.favoriteTracks(inSection: section.key)
                else { return }
                library = current
                fetched = again
            }
            favorites = fetched
            guard !fetched.isEmpty else {
                noFavorites = true
                return
            }
            let playable = allowed(fetched)
            guard !playable.isEmpty else {
                everyFavoriteHidden = true
                return
            }
            player.play(playable.spreadShuffled(), startingAt: 0, library: library)
            nowPlaying.isShown = true
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

/// Sits above the grid as a raised card so it reads as the one action on
/// the page rather than another row. The body shuffles; the chevron past
/// the rule opens the full list.
private struct ShuffleFavoritesCard: View {
    let subtitle: String?
    let loading: Bool
    let action: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(Color.heartInk)
                        .frame(width: 44, height: 44)
                        .background(Color.heart, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shuffle Favorites").font(.headline)
                        if let subtitle {
                            // One line: a longer listener list wrapping made
                            // the card grow as listeners toggled.
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "shuffle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.heart)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .disabled(loading)
            Rectangle()
                .fill(Color.divider)
                .frame(width: 1)
                .padding(.vertical, 12)
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .accessibilityLabel("All Favorites")
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 24)
    }
}

/// Half-width entry to a mix builder, sharing the hero card's chrome, in
/// the mix's own color so the two read apart at a glance.
private struct MixTile: View {
    let kind: MixKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(kind.accent)
                    .frame(width: 36, height: 36)
                    .background(kind.accent.opacity(0.16), in: .circle)
                // Half a phone's width is tight for "Mix Albums": one line,
                // shrunk a touch before it would wrap.
                Text(kind.title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
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
