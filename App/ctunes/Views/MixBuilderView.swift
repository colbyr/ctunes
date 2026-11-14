import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open Quick Mix: in its edit mode
/// on a pinned mix's picks, or on the last selection with no id.
struct MixRoute: Hashable {
    var mixID: SavedMix.ID? = nil
}

/// Picks artists, albums, playlists and the favorites, any mix of them,
/// and plays every track in the union as a one-shot queue, in order,
/// shuffled by track or album by album. The pool lists one kind at a
/// time, switched from the layout menu; a tap checks an item in place and
/// the picks of every kind gather in the mix bar, which takes the mini
/// player's slot (`MixDraft`, `MixBar`). The pool never offers what a
/// listening rider vetoed. What was played lands in the Music screen's
/// row of mixes, from which it plays again or is pinned. Opened on a
/// pinned mix, the page is that mix's editor: Cancel and Save in place of
/// back, the bar showing its picks with no play buttons.
struct MixBuilderView: View {
    let model: AppModel
    let section: PlexSection
    let route: MixRoute
    @Binding var query: String
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryNavigator.self) private var navigator
    @Environment(MixDraft.self) private var draft
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
    @State private var hooked = false
    /// The route's saved mix has been put in the bar; coming back from a
    /// page pushed over the builder shouldn't put it there again.
    @State private var routeApplied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    /// The pool's width, for the tile floor.
    @State private var width: CGFloat = 0
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

    /// Debug-only preselection from `CTUNES_DEV_MIX=<kind>:<key>,<key>`,
    /// the keys taken as that kind once the pool loads. Nil without a
    /// colon, so the saved picks apply; a bare `<kind>:` is an explicitly
    /// empty one.
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
        /// A listening rider has vetoed it. Off the pool, but still drawn
        /// dimmed wherever it is listed.
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
             unavailable: model.connection == .unreachable && !model.downloads.hasDownloads(playlist),
             download: model.downloads.state(playlist))
    }

    private var favoritesItem: Item {
        Item(pick: .favorites, subtitle: "Hearted tracks", vetoed: false,
             unavailable: model.connection == .unreachable && !model.isFavoritesPinned)
    }

    /// Under the album pool's Artists view the header names the artist, so
    /// the card shows the year instead; a pick always names its artist.
    private func item(album: PlexAlbum, showArtist: Bool = true) -> Item {
        Item(
            pick: MixPick(album: album),
            subtitle: album.subtitle(showArtist: showArtist),
            vetoed: hidden.hides(album),
            unavailable: model.connection == .unreachable && !model.downloads.hasDownloads(album),
            download: model.downloads.state(album)
        )
    }

    /// The album pool sectioned the way the main screen is. Search shows
    /// the flat ranked `rest` instead.
    private var poolGroups: [AlbumGroup] {
        AlbumBrowse.groups(browsable, view: albumSort, hiding: hidden, rotation: rotation)
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

    /// The pool narrowed by the search pill; picks stay in place, checked.
    private var rest: [Item] {
        guard !needle.isEmpty else { return pool }
        switch kind {
        case .artist, .playlist, .favorites:
            return pool.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        case .album:
            let ranked = AlbumBrowse.search(browsable, query: needle, view: albumSort, hiding: hidden, rotation: rotation).map(\.ratingKey)
            let byKey = Dictionary(pool.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
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
        [GridItem(.adaptive(minimum: BrowseTile.minimum(forWidth: width)), spacing: 12, alignment: .top)]
    }

    var body: some View {
        let editing = draft.editing.flatMap { model.shortcut($0) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AlbumBrowserControls(model: model, artists: AlbumBrowse.groups(albums, view: .artist), view: sort, layout: $layout,
                                         scope: subject.scope, subject: $subject, downloadedOnly: $downloadedOnly)
                        .padding(.top, 8)
                        .id(Self.poolAnchor)
                    HiddenLine(model: model, count: hiddenCount, downloadedOnly: downloadedOnly)
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
                                items(group.albums.map { item(album: $0, showArtist: albumSort != .artist) })
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
                        items(rest)
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
        // Room for the floating pills, the mix bar's two rows, and the
        // keyboard under them.
        .contentMargins(.bottom, (editing == nil ? 150 : 100) + (keyboard.isUp ? keyboard.height : 0), for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            }
        }
        .navigationTitle(editing.map { "Edit \($0.name)" } ?? "Mixer")
        .navigationSubtitle(editing == nil ? "" : "Tap to add or remove")
        .navigationBarTitleDisplayMode(.inline)
        // Editing is a mode with its own way out: back would leave it
        // unclear whether the change was kept.
        .navigationBarBackButtonHidden(editing != nil)
        .toolbar {
            if editing != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { draft.endEditing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { draft.saveEdit(model) }
                        .disabled(!draft.canSave(model))
                        .tint(Color.mix)
                }
            }
        }
        .toolbar { SearchBarItem() }
        // Handed the environment explicitly: a Mac window crossing the
        // compact/regular line re-hosts an open sheet without it.
        .sheet(isPresented: Bindable(draft).reviewing) {
            Group {
                if draft.editing != nil {
                    MixEditSheet(model: model)
                } else {
                    MixReviewSheet(model: model)
                }
            }
                .environment(draft)
                .environment(player)
                .environment(nowPlaying)
                .environment(navigator)
        }
        .onAppear {
            draft.building = true
            query = ""
            // A pinned mix opens its editor; otherwise the last picks are
            // waiting. An editor left some other way than its buttons (the
            // stack reset under it) is given up here.
            if !routeApplied, let id = route.mixID, let mix = model.shortcut(id) {
                draft.beginEditing(mix)
            } else if route.mixID == nil, draft.editing != nil {
                draft.endEditing()
            }
            if draft.editing == nil, !routeApplied, draft.picks.isEmpty, Self.developmentSelection == nil {
                draft.picks = MixDraft.saved(model)
            }
            routeApplied = true
        }
        .onDisappear { draft.building = false }
        // The editor's Save or Cancel, from the toolbar or the sheet: back
        // to where it was opened from.
        .onChange(of: draft.editing) { old, new in
            if route.mixID != nil, old != nil, new == nil { dismiss() }
        }
        .onChange(of: draft.picks) { draft.save(model) }
        .task(id: model.libraryRevision) {
            await load()
            #if DEBUG
            // Once: the task runs again on every revision.
            if !hooked, !albums.isEmpty, let ids = Self.developmentSelection {
                hooked = true
                draft.picks = ids.compactMap(developmentPick)
                draft.reviewing = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX_REVIEW"] != nil && !draft.picks.isEmpty
                if ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil {
                    draft.play(ProcessInfo.processInfo.environment["CTUNES_DEV_MIX_MODE"] == "albums" ? .mixAlbums : .shuffle,
                               actions: actions)
                }
            }
            #endif
        }
        .refreshable { await load() }
    }

    private var actions: LibraryActions {
        LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
    }

    #if DEBUG
    /// A `kind:key` from the dev hook as a pick from the loaded pool.
    private func developmentPick(_ id: String) -> MixPick? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch MixPickKind(rawValue: parts[0]) {
        case .artist: return artists.first { $0.ratingKey == parts[1] }.map(MixPick.init(artist:))
        case .album: return albums.first { $0.ratingKey == parts[1] }.map(MixPick.init(album:))
        case .playlist: return model.playlists.first { $0.ratingKey == parts[1] }.map(MixPick.init(playlist:))
        case .favorites: return .favorites
        case nil: return nil
        }
    }
    #endif

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

    @ViewBuilder private func items(_ items: [Item]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    let isSelected = draft.contains(item.id)
                    self.item(item, selected: isSelected) {
                        MixTile(item: item, selected: isSelected, url: model.library?.artworkURL(item.thumb))
                    }
                }
            }
        case .list:
            BrowseList(items: items) { item in
                let isSelected = draft.contains(item.id)
                BrowseRow(url: model.library?.artworkURL(item.thumb), round: item.kind == .artist,
                          placeholder: Self.placeholder(for: item.kind),
                          art: item.kind == .favorites ? AnyView(FavoritesArt(size: BrowseRow<EmptyView, EmptyView>.artSize, corner: 6)) : nil,
                          title: item.title,
                          subtitle: item.subtitle, download: item.download, dimmed: item.vetoed || item.unavailable, showsMore: false) {
                    draft.toggle(item.pick)
                } accessory: {
                    // A pick's check, or the plus that adds one.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.mix) : AnyShapeStyle(.secondary))
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
        Button { draft.toggle(item.pick) } label: { label() }
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
            ArtistMenu(model: model, ratingKey: item.key, title: item.title, showMixer: false)
        case .album:
            if let album = albums.first(where: { $0.ratingKey == item.key }) {
                AlbumMenu(model: model, album: album, showMixer: false)
            }
        case .playlist:
            if let playlist = model.playlists.first(where: { $0.ratingKey == item.key }) {
                PlaylistMenu(model: model, playlist: playlist, showMixer: false)
            }
        case .favorites:
            Button { navigator.open(.favorites) } label: {
                Label("Go to Favorites", systemImage: "heart")
            }
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
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.pillInk)
                                .frame(width: 24, height: 24)
                                .background(Color.mix, in: .circle)
                                .overlay(Circle().stroke(Color.parchmentTop, lineWidth: 2))
                                .padding(round ? 2 : 6)
                                .transition(.scale.combined(with: .opacity))
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

        private var ring: Color { .mix }

        @ViewBuilder private var art: some View {
            if round {
                Artwork(url: url, size: nil, corner: 8)
                    .clipShape(.circle)
                    .artworkShadow()
                    .overlay(alignment: .bottomTrailing) {
                        // Pulled in toward the rim, where a circle has room;
                        // a pick's check takes its place.
                        if !selected { DownloadBadge(state: item.download).padding(4) }
                    }
                    .overlay {
                        if selected {
                            Circle().stroke(ring, lineWidth: 3)
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
                .overlay(alignment: .bottomTrailing) {
                    if !selected { DownloadBadge(state: item.download) }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8).stroke(ring, lineWidth: 3)
                    }
                }
            }
        }
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
