import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the mix builder: on a saved
/// mix's picks, or on the last selection with no id.
struct MixRoute: Hashable {
    var mixID: SavedMix.ID? = nil
}

/// Picks artists, albums, playlists and the favorites, any mix of them,
/// and plays every track in the union as a one-shot queue, in order,
/// shuffled by track or album by album. The pool lists one kind at a
/// time, switched from the layout menu; the picks of every kind share the
/// grid above it. With nothing picked the mix is the whole library. The
/// pool never offers what a listening rider vetoed. Save keeps the picks
/// and a style under a name as a shortcut on the Music screen; opened on
/// a saved mix, Save updates it.
struct MixBuilderView: View {
    let model: AppModel
    let section: PlexSection
    let route: MixRoute
    @Binding var query: String
    @Binding var building: Bool
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryNavigator.self) private var navigator
    /// The stack ignores the keyboard, so the pool makes its own room.
    @Environment(KeyboardInset.self) private var keyboard

    @State private var artists: [PlexArtist] = []
    /// Fetched for both pools: the artist pool needs the albums' track
    /// counts to score artists.
    @State private var albums: [PlexAlbum] = []
    /// Scored once when the plays land; `.none` before then or when the
    /// request fails, which leaves On Rotation on the server's play counts.
    @State private var rotation: Rotation = .none
    @State private var loaded = false
    /// Pick ids (`MixPick.id`: `artist:<ratingKey>`, `favorites:`) in the
    /// order they were tapped.
    @State private var selected: [String] = []
    @State private var loadingMix: PlayStyle?
    @State private var nothingToPlay = false
    /// The saved mix the builder is editing: the route's, or the one just
    /// saved, so a second Save updates rather than adds.
    @State private var editing: SavedMix.ID?
    @State private var saving = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// What the pool lists: albums, artists or playlists (with the
    /// favorites at their head).
    @AppStorage("mixSubject") private var subject: BrowseSubject = .albums
    /// A sort per pool rather than the root's keys: arranging a pool by
    /// play count shouldn't reorder the album grid behind it. The layout
    /// is the app's.
    @AppStorage("mixView.artist") private var artistSort: AlbumView = .mostPlayed
    @AppStorage("mixView.album") private var albumSort: AlbumView = .mostPlayed
    @AppStorage("mixView.playlist") private var playlistSort: AlbumView = .artist
    @AppStorage("mixLayout") private var layout: BrowseLayout = .grid
    @AppStorage("mixDownloadedOnly.album") private var downloadedOnly = false
    /// Comma-joined pick ids, so the last mix is waiting next time.
    @AppStorage("mixSelection") private var savedSelection = ""

    /// Debug-only preselection from `CTUNES_DEV_MIX=<kind>:<key>,<key>`,
    /// the keys taken as that kind. Nil without a colon, so the saved
    /// selection applies; a bare `<kind>:` is an explicitly empty one.
    static var developmentSelection: [String]? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX"],
              let colon = raw.firstIndex(of: ":") else { return nil }
        let kind = raw[..<colon]
        return raw[raw.index(after: colon)...].split(separator: ",").map { "\(kind):\($0)" }
        #else
        return nil
        #endif
    }

    /// One shape for every kind so the grids render the same way.
    private struct Item: Identifiable {
        /// What a save keeps; its `id` is the selection's key.
        let pick: MixPick
        let subtitle: String?
        /// A listening rider has vetoed it. Stays in the selected grid,
        /// dimmed, so toggling the rider off brings it straight back.
        let vetoed: Bool
        /// Offline with nothing downloaded: still in the pool, dimmed.
        var unavailable = false
        /// What's on disk: the same badge as the browse root.
        var download: DownloadState = .none

        var id: String { pick.id }
        var kind: MixPickKind { pick.kind }
        var key: String { pick.ratingKey ?? "" }
        var title: String { pick.title }
        var thumb: String? { pick.thumb }
    }

    private var kind: MixPickKind {
        switch subject {
        case .artists: .artist
        case .albums: .album
        case .playlists: .playlist
        }
    }
    private var sort: Binding<AlbumView> {
        switch kind {
        case .artist: $artistSort
        case .album: $albumSort
        case .playlist, .favorites: $playlistSort
        }
    }
    private var hidden: VetoSet { model.roster.hidden }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }
    /// The album pool after the Downloaded only filter. Picks come from the
    /// unfiltered list, so turning the filter on never drops a selection.
    private var browsable: [PlexAlbum] {
        downloadedOnly ? albums.filter { model.downloads.hasDownloads($0) } : albums
    }
    /// The artist pool under the same filter: the artists with a
    /// downloaded album, as on the root.
    private var browsableArtists: [PlexArtist] {
        guard downloadedOnly else { return artists }
        let downloaded = Set(browsable.map(\.artistKey))
        return artists.filter { downloaded.contains($0.ratingKey) }
    }

    private func item(artist: PlexArtist) -> Item {
        Item(pick: MixPick(artist: artist), subtitle: nil,
             vetoed: hidden.artists.contains(artist.ratingKey), download: model.downloads.state(artist: artist.ratingKey))
    }

    /// A playlist is a mixed bag, so no veto hides it whole; offline it
    /// plays what was saved from it.
    private func item(playlist: PlexPlaylist) -> Item {
        Item(pick: MixPick(playlist: playlist), subtitle: playlist.subtitle, vetoed: false,
             unavailable: model.state == .offline && !model.downloads.hasDownloads(playlist),
             download: model.downloads.state(playlist))
    }

    private var favoritesItem: Item {
        Item(pick: .favorites, subtitle: "Hearted tracks", vetoed: false,
             unavailable: model.state == .offline && !model.isFavoritesPinned)
    }

    /// Under the album pool's Artists view the header names the artist, so
    /// the card shows the year instead; a pick always names its artist.
    private func item(album: PlexAlbum, showArtist: Bool = true) -> Item {
        Item(
            pick: MixPick(album: album),
            subtitle: album.subtitle(showArtist: showArtist),
            vetoed: hidden.hides(album),
            unavailable: model.state == .offline && !model.downloads.hasDownloads(album),
            download: model.downloads.state(album)
        )
    }

    /// The album pool sectioned the way the main screen is, minus the
    /// picks. Empty groups fall away with their albums. Search shows the
    /// flat ranked `rest` instead.
    private var poolGroups: [AlbumGroup] {
        let unpicked = browsable.filter { !selected.contains("album:\($0.ratingKey)") }
        return AlbumBrowse.groups(unpicked, view: albumSort, hiding: hidden, rotation: rotation)
    }

    /// The playlist pool under the Downloaded only filter: the ones with a
    /// saved item on disk, and the favorites once pinned.
    private var browsablePlaylists: [PlexPlaylist] {
        downloadedOnly ? model.playlists.filter { model.downloads.hasDownloads($0) } : model.playlists
    }

    /// The pool's kind, in sort order, minus what the vetoes hide. The
    /// favorites lead the playlists under every sort.
    private var pool: [Item] {
        switch kind {
        case .artist:
            artistSort.sorted(browsableArtists, rotation: rotation).map { item(artist: $0) }.filter { !$0.vetoed }
        case .album:
            albumSort.sorted(browsable, rotation: rotation).map { item(album: $0, showArtist: albumSort != .artist) }.filter { !$0.vetoed }
        case .playlist, .favorites:
            (downloadedOnly && !model.isFavoritesPinned ? [] : [favoritesItem])
                + playlistSort.sorted(browsablePlaylists).map { item(playlist: $0) }
        }
    }

    /// Selected items of every kind in tap order, vetoed ones included.
    private var picks: [Item] {
        let artistsByKey = Dictionary(artists.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        let albumsByKey = Dictionary(albums.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        let playlistsByKey = Dictionary(model.playlists.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { id in
            let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            switch MixPickKind(rawValue: parts[0]) {
            case .artist: return artistsByKey[parts[1]].map { item(artist: $0) }
            case .album: return albumsByKey[parts[1]].map { item(album: $0) }
            case .playlist: return playlistsByKey[parts[1]].map { item(playlist: $0) }
            case .favorites: return favoritesItem
            case nil: return nil
            }
        }
    }

    /// The picks that will actually go into the mix.
    private var playable: [Item] { picks.filter { !$0.vetoed } }

    /// The two cards: Play and Shuffle for one album, playlist or the
    /// favorites, Mix Albums and Shuffle for anything else.
    private var styles: [PlayStyle] { PlayStyle.cases(for: picks.map(\.pick)) }

    /// Search narrows `rest` only, so a pick never disappears from the
    /// selected grid.
    private var rest: [Item] {
        let unpicked = pool.filter { !selected.contains($0.id) }
        guard !needle.isEmpty else { return unpicked }
        switch kind {
        case .artist, .playlist, .favorites:
            return unpicked.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        case .album:
            let ranked = AlbumBrowse.search(browsable, query: needle, view: albumSort, hiding: hidden, rotation: rotation).map(\.ratingKey)
            let byKey = Dictionary(unpicked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            return ranked.compactMap { byKey[$0] }
        }
    }

    private var hiddenCount: HiddenCount {
        switch kind {
        case .artist: HiddenCount(artists: artists.filter { hidden.artists.contains($0.ratingKey) }.count)
        case .album: .over(albums, hidden: hidden)
        case .playlist, .favorites: HiddenCount()
        }
    }

    private static let margin: CGFloat = 16
    /// Where a search scrolls to: the controls over the pool.
    private static let poolAnchor = "pool"
    /// Same floor as the album browser: wider tiles on a regular width.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 100), spacing: 12, alignment: .top)]
    }

    var body: some View {
        let picks = picks
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MixActions(styles: styles, loading: loadingMix, action: play)
                        // Bottom inset clears the card's shadow; see `cardShadow`.
                        .padding(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                    Group {
                        if picks.isEmpty {
                            emptySelection
                        } else {
                            items(picks, selected: true)
                        }
                    }
                    .padding(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                    Rectangle()
                        .fill(Color.divider)
                        .frame(height: 1)
                        .padding(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    AlbumBrowserControls(model: model, artists: AlbumBrowse.groups(albums, view: .artist), view: sort, layout: $layout,
                                         scope: subject.scope, subject: $subject, downloadedOnly: $downloadedOnly)
                        .padding(.top, 16)
                        .id(Self.poolAnchor)
                    HiddenLine(model: model, count: hiddenCount)
                        .padding(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                    // In the stack rather than an overlay, so it sits under
                    // the picks and the controls instead of over them.
                    if loaded, rest.isEmpty, !needle.isEmpty {
                        ContentUnavailableView.search(text: needle)
                            .frame(maxWidth: .infinity)
                            .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    } else if loaded, pool.isEmpty {
                        ContentUnavailableView("Nothing to mix", systemImage: subject.systemImage)
                            .frame(maxWidth: .infinity)
                            .padding(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    } else if kind == .album && needle.isEmpty {
                        ForEach(poolGroups) { group in
                            Section {
                                items(group.albums.map { item(album: $0, showArtist: albumSort != .artist) }, selected: false)
                                    .padding(.init(top: group.name.isEmpty ? 14 : 2, leading: Self.margin, bottom: 0, trailing: Self.margin))
                            } header: {
                                if !group.name.isEmpty {
                                    AlbumGroupHeader(group: group)
                                        .padding(.leading, Self.margin)
                                        .padding(.top, 14)
                                        .padding(.bottom, 6)
                                }
                            }
                        }
                    } else {
                        items(rest, selected: false)
                            .padding(.init(top: 14, leading: Self.margin, bottom: 10, trailing: Self.margin))
                    }
                }
            }
            // A query brings the pool up under the bar. With only a few
            // results the scroll stops at the end of the content, which the
            // keyboard's margin below leaves just clear of the search pill.
            .onChange(of: needle) { _, needle in
                guard !needle.isEmpty else { return }
                withAnimation(.snappy) { proxy.scrollTo(Self.poolAnchor, anchor: .top) }
            }
        }
        .parchment()
        .scrollDismissesKeyboard(.immediately)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Past the action cards (about their height plus the row insets).
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 90
        } action: { _, scrolledPast in
            withAnimation(.snappy) { actionsVisible = !scrolledPast }
        }
        // Room for the floating pills, and for the keyboard under them.
        .contentMargins(.bottom, 84 + (keyboard.isUp ? keyboard.height : 0), for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            }
        }
        .navigationTitle(editing.flatMap { model.shortcut($0)?.name } ?? "Mix")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Keeps the picks as a shortcut on the Music screen; declared
            // first so it sits leftmost, ahead of the play icons.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save", systemImage: "bookmark") { saving = true }
                    .disabled(!loaded)
            }
            // The cards' actions follow you down the pool as icons.
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForEach(styles) { style in
                        Button(style.verb, systemImage: style.symbol) { play(style) }
                            .disabled(loadingMix != nil)
                    }
                }
            }
        }
        .sheet(isPresented: $saving) {
            SaveMixSheet(model: model, picks: picks.map(\.pick), editing: editing) { saved in editing = saved }
        }
        .onAppear {
            building = true
            query = ""
            // A saved mix opens on its picks; otherwise the last selection
            // is waiting, unless a dev hook names one.
            if let id = route.mixID, editing == nil, let mix = model.shortcut(id) {
                editing = id
                selected = mix.picks.map(\.id)
            } else if selected.isEmpty {
                selected = Self.developmentSelection ?? savedSelection.split(separator: ",").map(String.init)
            }
        }
        .onDisappear { building = false }
        .onChange(of: selected) { savedSelection = selected.joined(separator: ",") }
        .task(id: model.libraryGeneration) {
            await load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil {
                play(ProcessInfo.processInfo.environment["CTUNES_DEV_MIX_MODE"] == "albums" ? .mixAlbums : .shuffle)
            }
            #endif
        }
        .refreshable { await load() }
        .alert("Nothing to play", isPresented: $nothingToPlay) {
            Button("OK") {}
        } message: {
            Text("Nothing selected has any tracks to play right now.")
        }
    }

    /// The fetch: on appear, on a library swap, and on pull to refresh.
    /// Both lists every time, since picks of either kind can be waiting.
    private func load() async {
        guard let library = model.library else { return }
        async let plays = library.playHistory(inSection: section.key, since: .now - Rotation.window)
        async let artistList = library.artists(inSection: section.key)
        albums = (try? await library.albums(inSection: section.key)) ?? []
        artists = (try? await artistList) ?? []
        loaded = true
        let history = (try? await plays) ?? []
        rotation = Rotation(history: history, albums: albums)
    }

    /// Stands in for the selected items, sized by an invisible tile in the
    /// same columns, or one invisible row, so the pool doesn't jump when
    /// the first pick lands.
    private var emptySelection: some View {
        let blank = Item(pick: .album(ratingKey: "", title: " ", artistKey: nil, artist: nil, thumb: nil), subtitle: " ", vetoed: false)
        return items([blank], selected: false)
            .hidden()
            .overlay {
                Text("Mix the whole library, or pick artists, albums and playlists below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
    }

    @ViewBuilder private func items(_ items: [Item], selected isSelected: Bool) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    self.item(item, selected: isSelected) {
                        MixTile(item: item, selected: isSelected, url: model.library?.artworkURL(item.thumb))
                    }
                }
            }
        case .list:
            BrowseList(items: items) { item in
                BrowseRow(url: model.library?.artworkURL(item.thumb), round: item.kind == .artist,
                          placeholder: Self.placeholder(for: item.kind),
                          art: item.kind == .favorites ? AnyView(FavoritesArt(size: BrowseRow<EmptyView, EmptyView>.artSize, corner: 6)) : nil,
                          title: item.title,
                          subtitle: item.subtitle, download: item.download, dimmed: item.vetoed || item.unavailable, showsMore: false) {
                    toggle(item.id)
                } accessory: {
                    // A pick's mark, or the plus that adds one; the ring
                    // color from the tiles, gray once vetoed.
                    Image(systemName: isSelected ? "xmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? (item.vetoed ? .gray : Color.mix) : .secondary)
                } menu: {
                    menu(for: item)
                }
                .accessibilityLabel(isSelected ? "Remove \(item.title)" : "Add \(item.title)")
                .accessibilityHint(item.vetoed ? "Hidden for a listener, so it won't be played" : "")
            }
        }
    }

    /// One tile: a tap toggles it, a long press gets the same menu the
    /// tile has elsewhere.
    private func item(_ item: Item, selected isSelected: Bool, @ViewBuilder label: () -> some View) -> some View {
        Button { toggle(item.id) } label: { label() }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Remove \(item.title)" : "Add \(item.title)")
            .accessibilityHint(item.vetoed ? "Hidden for a listener, so it won't be played" : "")
            .contextMenu { menu(for: item) }
    }

    /// The glyph while there is no image: a heart for the favorites, a
    /// list for a playlist without a composite yet.
    fileprivate static func placeholder(for kind: MixPickKind) -> String {
        switch kind {
        case .favorites: "heart.fill"
        case .playlist: "music.note.list"
        case .artist: "music.microphone"
        case .album: "music.note"
        }
    }

    @ViewBuilder private func menu(for item: Item) -> some View {
        switch item.kind {
        case .artist:
            ArtistMenu(model: model, ratingKey: item.key, title: item.title)
        case .album:
            if let album = albums.first(where: { $0.ratingKey == item.key }) {
                AlbumMenu(model: model, album: album)
            }
        case .playlist:
            if let playlist = model.playlists.first(where: { $0.ratingKey == item.key }) {
                PlaylistMenu(model: model, playlist: playlist)
            }
        case .favorites:
            Button { navigator.open(.favorites) } label: {
                Label("Go to Favorites", systemImage: "heart")
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            if let index = selected.firstIndex(of: id) {
                selected.remove(at: index)
            } else {
                selected.append(id)
            }
        }
    }

    /// Every track across the selection, or the whole library when nothing
    /// is picked, ordered once at enqueue time: in pick order, spread-
    /// shuffled like Shuffle Favorites, or kept in whole albums with only
    /// the album order shuffled. The fetch is the shortcut cards' own.
    private func play(_ mode: PlayStyle) {
        guard let library = model.library, loadingMix == nil else { return }
        let picked = playable.map(\.pick)
        guard selected.isEmpty || !picked.isEmpty else {
            nothingToPlay = true
            return
        }
        loadingMix = mode
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        Task {
            defer { loadingMix = nil }
            var tracks = await actions.tracks(of: picked)
            // Nothing picked under Downloaded only: the albums the filter shows.
            if picked.isEmpty, downloadedOnly {
                let shown = Set(browsable.map(\.ratingKey))
                tracks = tracks.filter { shown.contains($0.parentRatingKey ?? "") }
            }
            // A pick's vetoed albums and tracks drop out here; offline,
            // only what's on disk can go in the queue.
            let playable = actions.playable(tracks, within: nil)
            guard !playable.isEmpty else {
                nothingToPlay = true
                return
            }
            player.play(mode.ordered(playable), startingAt: 0, library: library)
            nowPlaying.isShown = true
        }
    }

    private struct MixTile: View {
        let item: Item
        let selected: Bool
        let url: URL?

        private var round: Bool { item.kind == .artist }
        private var favorites: Bool { item.kind == .favorites }

        var body: some View {
            VStack(alignment: round ? .center : .leading, spacing: 8) {
                art
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.pillInk)
                                .frame(width: 24, height: 24)
                                .background(Color.pill, in: .circle)
                                .overlay(Circle().stroke(Color.parchmentTop, lineWidth: 2))
                                .offset(x: round ? 0 : 6, y: round ? 0 : -6)
                        }
                    }
                VStack(alignment: round ? .center : .leading, spacing: 1) {
                    Text(item.title)
                        .font(.footnote)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: round ? .center : .leading)
            }
            .frame(maxWidth: .infinity)
            .opacity(item.vetoed || item.unavailable ? 0.4 : 1)
            .contentShape(.rect)
        }

        private var ring: Color { item.vetoed ? .gray : .mix }

        @ViewBuilder private var art: some View {
            if round {
                Artwork(url: url, size: nil, corner: 8)
                    .clipShape(.circle)
                    .artworkShadow()
                    .overlay(alignment: .bottomTrailing) {
                        // Pulled in toward the rim, where a circle has room.
                        DownloadBadge(state: item.download).padding(4)
                    }
                    .overlay {
                        if selected {
                            Circle().stroke(ring, lineWidth: 2)
                        }
                    }
            } else {
                Group {
                    if favorites {
                        FavoritesArt(size: nil, corner: 8)
                    } else {
                        Artwork(url: url, size: nil, corner: 8, placeholder: MixBuilderView.placeholder(for: item.kind))
                    }
                }
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) { DownloadBadge(state: item.download) }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8).stroke(ring, lineWidth: 2)
                    }
                }
            }
        }
    }
}

/// The actions at the top of the page, styled like the shortcut cards on
/// the root: two cards, always live, since an empty selection mixes
/// everything. Which two follows the picks.
private struct MixActions: View {
    let styles: [PlayStyle]
    let loading: PlayStyle?
    let action: (PlayStyle) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(styles) { style in
                MixActionCard(
                    systemImage: style.symbol, title: style.verb, subtitle: nil,
                    enabled: loading == nil || loading == style, loading: loading == style,
                    tint: .mix
                ) { action(style) }
            }
        }
        .animation(.snappy, value: styles)
    }
}

/// A play action as a raised card. Shared with the Favorites page, whose
/// Play and Shuffle pair reads the same way.
struct MixActionCard: View {
    let systemImage: String
    let title: String
    /// Nil for the side-by-side pair, where the title has the width.
    let subtitle: String?
    let enabled: Bool
    let loading: Bool
    /// The icon and its disc: the page's own color, or nil for the art's
    /// accent on a page that has one and the amber otherwise.
    let tint: Color?
    let action: () -> Void
    @Environment(\.artworkAccent) private var artworkAccent

    /// Title-only cards share a row, so they tighten up.
    private var compact: Bool { subtitle == nil }

    var body: some View {
        let tint = tint ?? artworkAccent ?? .accentText
        Button(action: action) {
            HStack(spacing: compact ? 10 : 14) {
                Image(systemName: systemImage)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                    .foregroundStyle(enabled ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                    .background(enabled ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.fill.tertiary), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(enabled ? .primary : .secondary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if loading {
                    ProgressView()
                }
            }
            .padding(compact ? 12 : 14)
            .glassCard()
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
