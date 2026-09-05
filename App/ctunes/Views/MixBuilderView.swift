import PlexKit
import SwiftUI

/// Which kind of mix a builder assembles. Pushed onto the navigation path.
enum MixKind: String, Hashable {
    case artist, album

    var title: String {
        switch self {
        case .artist: "Artist Mix"
        case .album: "Album Mix"
        }
    }

    /// Amber for both: one accent, spent only where something acts.
    var accent: Color { .accentText }

    var systemImage: String {
        switch self {
        case .artist: "person.2.fill"
        case .album: "square.stack.fill"
        }
    }

    var noun: String {
        switch self {
        case .artist: "artists"
        case .album: "albums"
        }
    }
}

/// How a mix is laid out in the queue.
enum MixMode: Hashable {
    /// Every track in the union, spread-shuffled by artist then album.
    case shuffleTracks
    /// Whole albums front to back, the albums spread-shuffled by artist.
    case playAlbums
}

/// Picks a set of artists or albums and plays every track in the union as
/// a one-shot queue, shuffled by track or album by album. With nothing
/// picked the mix is the whole pool. The pool never offers an artist a
/// listening rider has vetoed.
struct MixBuilderView: View {
    let model: AppModel
    let section: PlexSection
    let kind: MixKind
    @Binding var query: String
    @Binding var building: Bool
    @Environment(AudioPlayer.self) private var player

    @State private var artists: [PlexArtist] = []
    @State private var albums: [PlexAlbum] = []
    @State private var loaded = false
    /// Rating keys in the order they were tapped.
    @State private var selected: [String] = []
    @State private var loadingMix: MixMode?
    @State private var nothingToPlay = false
    @State private var showingNowPlaying = false
    /// Per builder rather than the root's key: arranging a pool by play
    /// count shouldn't reorder the album grid behind it.
    @AppStorage private var view: AlbumView
    /// Album pool only; there is no per-artist download state.
    @AppStorage private var downloadedOnly: Bool
    /// Comma-joined ratingKeys, so the last mix is waiting next time.
    @AppStorage private var savedSelection: String

    init(model: AppModel, section: PlexSection, kind: MixKind, query: Binding<String>, building: Binding<Bool>) {
        self.model = model
        self.section = section
        self.kind = kind
        _query = query
        _building = building
        _view = AppStorage(wrappedValue: .recentlyAdded, "mixView.\(kind.rawValue)")
        _downloadedOnly = AppStorage(wrappedValue: false, "mixDownloadedOnly.\(kind.rawValue)")
        _savedSelection = AppStorage(wrappedValue: "", "mixSelection.\(kind.rawValue)")
    }

    /// Debug-only preselection from `CTUNES_DEV_MIX=<kind>:<key>,<key>`.
    /// Nil without a colon, so the saved selection applies; a bare
    /// `<kind>:` is an explicitly empty one.
    static var developmentSelection: [String]? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX"],
              let colon = raw.firstIndex(of: ":") else { return nil }
        return raw[raw.index(after: colon)...].split(separator: ",").map(String.init)
        #else
        return nil
        #endif
    }

    /// One shape for both kinds so the grids render the same way.
    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let thumb: String?
        /// A listening rider has vetoed the artist. Stays in the selected
        /// grid, dimmed, so toggling the rider off brings it straight back.
        let vetoed: Bool
        /// Offline with nothing downloaded: still in the pool, dimmed.
        var unavailable = false
        /// Every track on disk: the same badge as the browse root.
        var downloaded = false
    }

    private var hidden: Set<String> { model.roster.hiddenArtistKeys }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }
    /// The album pool after the Downloaded only filter. Picks come from the
    /// unfiltered list, so turning the filter on never drops a selection.
    private var browsable: [PlexAlbum] {
        downloadedOnly ? albums.filter { model.downloads.hasDownloads($0) } : albums
    }

    /// Everything in the section, in sort order, vetoes marked.
    private var items: [Item] {
        switch kind {
        case .artist:
            return view.sorted(artists).map {
                Item(id: $0.ratingKey, title: $0.title, subtitle: nil, thumb: $0.thumb, vetoed: hidden.contains($0.ratingKey))
            }
        case .album:
            let list = view.sorted(albums)
            return list.map(item)
        }
    }

    /// Under the artist view the header names the artist, so the card
    /// shows the year instead.
    private func item(_ album: PlexAlbum) -> Item {
        Item(
            id: album.ratingKey,
            title: album.title,
            subtitle: view == .artist ? (album.year.map(String.init) ?? "—") : album.parentTitle,
            thumb: album.thumb,
            vetoed: hidden.contains(album.artistKey),
            unavailable: model.state == .offline && !model.downloads.hasDownloads(album),
            downloaded: model.downloads.isDownloaded(album)
        )
    }

    /// The album pool sectioned the way the main screen is, minus the
    /// picks. Empty groups fall away with their albums. Search shows the
    /// flat ranked `rest` instead.
    private var poolGroups: [AlbumGroup] {
        let unpicked = browsable.filter { !selected.contains($0.ratingKey) }
        return AlbumBrowse.groups(unpicked, view: view, hiding: hidden)
    }

    /// What survives the vetoes. Search narrows `rest` only, so a pick
    /// never disappears from the selected grid.
    private var pool: [Item] { items.filter { !$0.vetoed } }

    /// Selected items in tap order, vetoed ones included.
    private var picks: [Item] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { byID[$0] }
    }

    /// The picks that will actually go into the mix.
    private var playable: [Item] { picks.filter { !$0.vetoed } }

    private var rest: [Item] {
        let unpicked = pool.filter { !selected.contains($0.id) }
        guard !needle.isEmpty else { return unpicked }
        switch kind {
        case .artist:
            return unpicked.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        case .album:
            let ranked = AlbumBrowse.search(browsable, query: needle, view: view, hiding: hidden).map(\.ratingKey)
            let byID = Dictionary(unpicked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ranked.compactMap { byID[$0] }
        }
    }

    private var hiddenCount: Int {
        switch kind {
        case .artist: artists.filter { hidden.contains($0.ratingKey) }.count
        case .album: Set(albums.map(\.artistKey).filter { hidden.contains($0) }).count
        }
    }

    private static let margin: CGFloat = 16
    private static let columns = [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .top)]

    var body: some View {
        let picks = picks
        let playable = playable
        List {
            MixActions(kind: kind, loading: loadingMix, action: play)
                // Bottom inset clears the card's shadow; see `cardShadow`.
                .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            Group {
                if picks.isEmpty {
                    emptySelection
                } else {
                    grid(picks, selected: true)
                }
            }
            .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
            .listRowBackground(Color.clear)
            Rectangle()
                .fill(Color.divider)
                .frame(height: 1)
                .listRowInsets(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            AlbumBrowserControls(model: model, view: $view, downloadedOnly: kind == .album ? $downloadedOnly : nil)
                .listRowInsets(.init(top: 16, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            HiddenArtistsLine(model: model, count: hiddenCount)
                .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if kind == .album && needle.isEmpty {
                ForEach(poolGroups) { group in
                    Section {
                        grid(group.albums.map(item), selected: false)
                            .listRowInsets(.init(top: group.name.isEmpty ? 14 : 2, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    } header: {
                        if !group.name.isEmpty {
                            AlbumGroupHeader(group: group)
                                .padding(.leading, Self.margin)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                grid(rest, selected: false)
                    .listRowInsets(.init(top: 14, leading: Self.margin, bottom: 10, trailing: Self.margin))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .parchment()
        // The separator is a 1pt row; the default minimum centres it in 44pt.
        .environment(\.defaultMinListRowHeight, 1)
        .listSectionSpacing(0)
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            } else if rest.isEmpty && !needle.isEmpty {
                ContentUnavailableView.search(text: needle)
            } else if pool.isEmpty {
                ContentUnavailableView("Nothing to mix", systemImage: kind.systemImage)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { withAnimation(.snappy) { selected = [] } }
                    .disabled(picks.isEmpty)
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
            guard let library = model.library else { return }
            switch kind {
            case .artist: artists = (try? await library.artists(inSection: section.key)) ?? []
            case .album: albums = (try? await library.albums(inSection: section.key)) ?? []
            }
            loaded = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil {
                play(ProcessInfo.processInfo.environment["CTUNES_DEV_MIX_MODE"] == "albums" ? .playAlbums : .shuffleTracks)
            }
            #endif
        }
        .alert("Nothing to play", isPresented: $nothingToPlay) {
            Button("OK") {}
        } message: {
            Text("None of the selected \(kind.noun) have any tracks to play right now.")
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(model: model)
        }
    }

    /// Stands in for the selected grid, sized by an invisible tile in the
    /// same columns so the pool doesn't jump when the first pick lands.
    private var emptySelection: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
            MixTile(kind: kind, item: Item(id: "", title: " ", subtitle: " ", thumb: nil, vetoed: false), selected: false, url: nil)
                .hidden()
        }
        .overlay {
            Text("Mix all \(kind.noun), or pick specific ones below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .listRowSeparator(.hidden)
    }

    private func grid(_ items: [Item], selected isSelected: Bool) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                Button { toggle(item.id) } label: {
                    MixTile(kind: kind, item: item, selected: isSelected, url: model.library?.artworkURL(item.thumb))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Remove \(item.title)" : "Add \(item.title)")
                .accessibilityHint(item.vetoed ? "Hidden for a listener, so it won't be played" : "")
            }
        }
        .listRowSeparator(.hidden)
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

    /// Every track across the selection, or the whole pool when nothing is
    /// picked, fetched concurrently, then ordered once at enqueue time:
    /// spread-shuffled like Shuffle Favorites, or kept in whole albums with
    /// only the album order shuffled.
    private func play(_ mode: MixMode) {
        guard let library = model.library, loadingMix == nil else { return }
        let keys = playable.map(\.id)
        guard selected.isEmpty || !keys.isEmpty else {
            nothingToPlay = true
            return
        }
        loadingMix = mode
        Task {
            defer { loadingMix = nil }
            let kind = kind
            let section = section.key
            let tracks: [PlexTrack]
            if keys.isEmpty {
                // Nothing picked: the whole section in one request. Under
                // Downloaded only, the pool is what the filter shows.
                let all = (try? await library.tracks(inSection: section)) ?? []
                if downloadedOnly, kind == .album {
                    let shown = Set(browsable.map(\.ratingKey))
                    tracks = all.filter { shown.contains($0.parentRatingKey ?? "") }
                } else {
                    tracks = all
                }
            } else {
                tracks = await withTaskGroup(of: [PlexTrack].self) { group in
                    for key in keys {
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
            }
            // Offline, only what's on disk can go in the queue.
            let offline = model.state == .offline
            let playable = tracks.filter {
                !hidden.contains($0.grandparentRatingKey ?? "") && (!offline || model.downloads.isAvailable($0))
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
            showingNowPlaying = true
        }
    }

    private struct MixTile: View {
        let kind: MixKind
        let item: Item
        let selected: Bool
        let url: URL?

        var body: some View {
            VStack(alignment: kind == .artist ? .center : .leading, spacing: 8) {
                art
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.pillInk)
                                .frame(width: 24, height: 24)
                                .background(Color.pill, in: .circle)
                                .overlay(Circle().stroke(Color.parchmentTop, lineWidth: 2))
                                .offset(x: kind == .artist ? 0 : 6, y: kind == .artist ? 0 : -6)
                        }
                    }
                VStack(alignment: kind == .artist ? .center : .leading, spacing: 1) {
                    Text(item.title)
                        .font(.footnote)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: kind == .artist ? .center : .leading)
            }
            .frame(maxWidth: .infinity)
            .opacity(item.vetoed || item.unavailable ? 0.4 : 1)
            .contentShape(.rect)
        }

        private var ring: Color { item.vetoed ? .gray : kind.accent }

        @ViewBuilder private var art: some View {
            switch kind {
            case .artist:
                Artwork(url: url, size: nil, corner: 8)
                    .clipShape(.circle)
                    .artworkShadow()
                    .overlay {
                        if selected {
                            Circle().stroke(ring, lineWidth: 2)
                        }
                    }
            case .album:
                Artwork(url: url, size: nil, corner: 8)
                    .artworkShadow()
                    .overlay(alignment: .bottomTrailing) {
                        if item.downloaded { DownloadedBadge() }
                    }
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
    let kind: MixKind
    let loading: MixMode?
    let action: (MixMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            MixActionCard(
                kind: kind, systemImage: "square.on.square", title: "Mix Albums", subtitle: nil,
                enabled: loading == nil || loading == .playAlbums, loading: loading == .playAlbums
            ) { action(.playAlbums) }
            MixActionCard(
                kind: kind, systemImage: "shuffle", title: "Mix Tracks", subtitle: nil,
                enabled: loading == nil || loading == .shuffleTracks, loading: loading == .shuffleTracks
            ) { action(.shuffleTracks) }
        }
    }
}

private struct MixActionCard: View {
    let kind: MixKind
    let systemImage: String
    let title: String
    /// Nil for the side-by-side pair, where the title has the width.
    let subtitle: String?
    let enabled: Bool
    let loading: Bool
    let action: () -> Void

    /// Title-only cards share a row, so they tighten up.
    private var compact: Bool { subtitle == nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 10 : 14) {
                Image(systemName: systemImage)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                    .foregroundStyle(enabled ? AnyShapeStyle(Color.chipInk) : AnyShapeStyle(.tertiary))
                    .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                    .background(enabled ? AnyShapeStyle(Color.chip) : AnyShapeStyle(.fill.tertiary), in: .circle)
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
