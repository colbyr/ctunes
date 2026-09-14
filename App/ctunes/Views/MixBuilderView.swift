import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the mix builder.
struct MixRoute: Hashable {}

/// What a pick is. A mix holds artists, albums, or some of each.
enum MixKind: String, Hashable {
    case artist, album
}

/// How a mix is laid out in the queue.
enum MixMode: Hashable {
    /// Every track in the union, spread-shuffled by artist then album.
    case shuffleTracks
    /// Whole albums front to back, the albums spread-shuffled by artist.
    case playAlbums
}

/// Picks artists and albums, any mix of the two, and plays every track in
/// the union as a one-shot queue, shuffled by track or album by album. The
/// pool lists one kind at a time, switched from the layout menu; the picks
/// of both kinds share the grid above it. With nothing picked the mix is
/// the whole library. The pool never offers what a listening rider vetoed.
struct MixBuilderView: View {
    let model: AppModel
    let section: PlexSection
    @Binding var query: String
    @Binding var building: Bool
    @Environment(AudioPlayer.self) private var player
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
    /// Pick ids (`artist:<ratingKey>`, `album:<ratingKey>`) in the order
    /// they were tapped.
    @State private var selected: [String] = []
    @State private var loadingMix: MixMode?
    @State private var nothingToPlay = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// What the pool lists: albums or artists, never playlists.
    @AppStorage("mixSubject") private var subject: BrowseSubject = .albums
    /// A sort per pool rather than the root's keys: arranging a pool by
    /// play count shouldn't reorder the album grid behind it. The layout
    /// is the app's.
    @AppStorage("mixView.artist") private var artistSort: AlbumView = .mostPlayed
    @AppStorage("mixView.album") private var albumSort: AlbumView = .mostPlayed
    @AppStorage(BrowseLayout.key) private var layout: BrowseLayout = .grid
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

    /// One shape for both kinds so the grids render the same way.
    private struct Item: Identifiable {
        let kind: MixKind
        let key: String
        let title: String
        let subtitle: String?
        let thumb: String?
        /// A listening rider has vetoed it. Stays in the selected grid,
        /// dimmed, so toggling the rider off brings it straight back.
        let vetoed: Bool
        /// Offline with nothing downloaded: still in the pool, dimmed.
        var unavailable = false
        /// What's on disk: the same badge as the browse root.
        var download: DownloadState = .none

        var id: String { "\(kind.rawValue):\(key)" }
    }

    private var kind: MixKind { subject == .artists ? .artist : .album }
    private var sort: Binding<AlbumView> { kind == .artist ? $artistSort : $albumSort }
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
        Item(kind: .artist, key: artist.ratingKey, title: artist.title, subtitle: nil, thumb: artist.thumb,
             vetoed: hidden.artists.contains(artist.ratingKey), download: model.downloads.state(artist: artist.ratingKey))
    }

    /// Under the album pool's Artists view the header names the artist, so
    /// the card shows the year instead; a pick always names its artist.
    private func item(album: PlexAlbum, showArtist: Bool = true) -> Item {
        Item(
            kind: .album,
            key: album.ratingKey,
            title: album.title,
            subtitle: album.subtitle(showArtist: showArtist),
            thumb: album.thumb,
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

    /// The pool's kind, in sort order, minus what the vetoes hide.
    private var pool: [Item] {
        switch kind {
        case .artist:
            artistSort.sorted(browsableArtists, rotation: rotation).map { item(artist: $0) }.filter { !$0.vetoed }
        case .album:
            albumSort.sorted(browsable, rotation: rotation).map { item(album: $0, showArtist: albumSort != .artist) }.filter { !$0.vetoed }
        }
    }

    /// Selected items of both kinds in tap order, vetoed ones included.
    private var picks: [Item] {
        let artistsByKey = Dictionary(artists.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        let albumsByKey = Dictionary(albums.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { id in
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch MixKind(rawValue: parts[0]) {
            case .artist: return artistsByKey[parts[1]].map { item(artist: $0) }
            case .album: return albumsByKey[parts[1]].map { item(album: $0) }
            case nil: return nil
            }
        }
    }

    /// The picks that will actually go into the mix.
    private var playable: [Item] { picks.filter { !$0.vetoed } }

    /// Search narrows `rest` only, so a pick never disappears from the
    /// selected grid.
    private var rest: [Item] {
        let unpicked = pool.filter { !selected.contains($0.id) }
        guard !needle.isEmpty else { return unpicked }
        switch kind {
        case .artist:
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
                    MixActions(loading: loadingMix, action: play)
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
                                         scope: kind == .artist ? .artists : .albums, subject: $subject,
                                         subjects: [.albums, .artists], downloadedOnly: $downloadedOnly)
                        .padding(.top, 16)
                        .id(Self.poolAnchor)
                    HiddenLine(model: model, count: hiddenCount)
                        .padding(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                    if kind == .album && needle.isEmpty {
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
            } else if rest.isEmpty && !needle.isEmpty {
                ContentUnavailableView.search(text: needle)
            } else if pool.isEmpty {
                ContentUnavailableView("Nothing to mix", systemImage: kind == .artist ? "person.2" : "square.stack")
            }
        }
        .navigationTitle("Mix")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The cards' actions follow you down the pool as icons.
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Mix Albums", systemImage: "square.stack") { play(.playAlbums) }
                        .disabled(loadingMix != nil)
                    Button("Shuffle", systemImage: "shuffle") { play(.shuffleTracks) }
                        .disabled(loadingMix != nil)
                }
            }
        }
        .onAppear {
            building = true
            query = ""
            if selected.isEmpty {
                selected = Self.developmentSelection ?? savedSelection.split(separator: ",").map(String.init)
            }
        }
        .onDisappear { building = false }
        .onChange(of: selected) { savedSelection = selected.joined(separator: ",") }
        .task(id: model.libraryGeneration) {
            await load()
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil {
                play(ProcessInfo.processInfo.environment["CTUNES_DEV_MIX_MODE"] == "albums" ? .playAlbums : .shuffleTracks)
            }
            #endif
        }
        .refreshable { await load() }
        .alert("Nothing to play", isPresented: $nothingToPlay) {
            Button("OK") {}
        } message: {
            Text("None of the selected artists or albums have any tracks to play right now.")
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
        let blank = Item(kind: .album, key: "", title: " ", subtitle: " ", thumb: nil, vetoed: false)
        return items([blank], selected: false)
            .hidden()
            .overlay {
                Text("Mix the whole library, or pick artists and albums below.")
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
                BrowseRow(url: model.library?.artworkURL(item.thumb), round: item.kind == .artist, title: item.title,
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

    @ViewBuilder private func menu(for item: Item) -> some View {
        switch item.kind {
        case .artist:
            ArtistMenu(model: model, ratingKey: item.key, title: item.title)
        case .album:
            if let album = albums.first(where: { $0.ratingKey == item.key }) {
                AlbumMenu(model: model, album: album)
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
    /// is picked, fetched concurrently, then ordered once at enqueue time:
    /// spread-shuffled like Shuffle Favorites, or kept in whole albums with
    /// only the album order shuffled. An album picked alongside its artist
    /// goes in once.
    private func play(_ mode: MixMode) {
        guard let library = model.library, loadingMix == nil else { return }
        let picked = playable.map { ($0.kind, $0.key) }
        guard selected.isEmpty || !picked.isEmpty else {
            nothingToPlay = true
            return
        }
        loadingMix = mode
        Task {
            defer { loadingMix = nil }
            let section = section.key
            let tracks: [PlexTrack]
            if picked.isEmpty {
                // Nothing picked: the whole section in one request. Under
                // Downloaded only, the albums the filter shows.
                let all = (try? await library.tracks(inSection: section)) ?? []
                if downloadedOnly {
                    let shown = Set(browsable.map(\.ratingKey))
                    tracks = all.filter { shown.contains($0.parentRatingKey ?? "") }
                } else {
                    tracks = all
                }
            } else {
                let fetched = await withTaskGroup(of: [PlexTrack].self) { group in
                    for (kind, key) in picked {
                        group.addTask {
                            switch kind {
                            case .artist: (try? await library.tracks(forArtist: key, inSection: section)) ?? []
                            case .album: (try? await library.tracks(inAlbum: key)) ?? []
                            }
                        }
                    }
                    var all: [PlexTrack] = []
                    for await batch in group { all += batch }
                    return all
                }
                var seen: Set<String> = []
                tracks = fetched.filter { seen.insert($0.ratingKey).inserted }
            }
            // A pick's vetoed albums and tracks drop out here; offline,
            // only what's on disk can go in the queue.
            let offline = model.state == .offline
            let playable = tracks.filter {
                !hidden.hides($0) && (!offline || model.downloads.isAvailable($0))
            }
            guard !playable.isEmpty else {
                nothingToPlay = true
                return
            }
            let ordered = switch mode {
            case .shuffleTracks: playable.spreadShuffled()
            case .playAlbums: playable.albumShuffled()
            }
            player.play(ordered, startingAt: 0, library: library)
            nowPlaying.isShown = true
        }
    }

    private struct MixTile: View {
        let item: Item
        let selected: Bool
        let url: URL?

        private var round: Bool { item.kind == .artist }

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
                Artwork(url: url, size: nil, corner: 8)
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

/// The actions at the top of the page, styled like Shuffle Favorites on the
/// root: a card per mode, always live, since an empty selection mixes
/// everything.
private struct MixActions: View {
    let loading: MixMode?
    let action: (MixMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            MixActionCard(
                systemImage: "square.stack", title: "Mix Albums", subtitle: nil,
                enabled: loading == nil || loading == .playAlbums, loading: loading == .playAlbums,
                tint: .mix
            ) { action(.playAlbums) }
            MixActionCard(
                systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                enabled: loading == nil || loading == .shuffleTracks, loading: loading == .shuffleTracks,
                tint: .mix
            ) { action(.shuffleTracks) }
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
