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

    var accent: Color {
        switch self {
        case .artist: .indigo
        case .album: .orange
        }
    }

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

/// Picks a set of artists or albums and shuffles every track in the union
/// into a one-shot queue. Nothing is saved: pop the screen and the selection
/// is gone. The pool never offers an artist a listening rider has vetoed.
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
    @State private var loadingMix = false
    @State private var nothingToPlay = false
    @State private var showingNowPlaying = false
    @AppStorage("albumSort") private var sort: AlbumSort = .recentlyAdded

    /// Debug-only preselection from `CTUNES_DEV_MIX=<kind>:<key>,<key>`.
    static var developmentSelection: [String] {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX"],
              let colon = raw.firstIndex(of: ":") else { return [] }
        return raw[raw.index(after: colon)...].split(separator: ",").map(String.init)
        #else
        return []
        #endif
    }

    /// One shape for both kinds so the grids render the same way.
    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let thumb: String?
        let artistKey: String
    }

    private var hidden: Set<String> { model.roster.hiddenArtistKeys }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }

    /// Everything in the section that survives the vetoes. Search narrows
    /// `rest` only, so a pick never disappears from the selected grid.
    private var pool: [Item] {
        switch kind {
        case .artist:
            return artists
                .filter { !hidden.contains($0.ratingKey) }
                .map { Item(id: $0.ratingKey, title: $0.title, subtitle: nil, thumb: $0.thumb, artistKey: $0.ratingKey) }
        case .album:
            let list = AlbumBrowse.groups(albums, sort: sort, grouping: .none, hiding: hidden).first?.albums ?? []
            return list.map { Item(id: $0.ratingKey, title: $0.title, subtitle: $0.parentTitle, thumb: $0.thumb, artistKey: $0.artistKey) }
        }
    }

    /// Selected items in tap order. Filtered through the pool, so an artist
    /// vetoed after being picked drops out of the mix on its own.
    private var picks: [Item] {
        let visible = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { visible[$0] }
    }

    private var rest: [Item] {
        let unpicked = pool.filter { !selected.contains($0.id) }
        guard !needle.isEmpty else { return unpicked }
        switch kind {
        case .artist:
            return unpicked.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        case .album:
            let ranked = AlbumBrowse.search(albums, query: needle, sort: sort, hiding: hidden).map(\.ratingKey)
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
        List {
            PlayMixCard(kind: kind, picks: picks.map(\.title), loading: loadingMix, action: play)
                .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 12, trailing: Self.margin))
                .listRowSeparator(.hidden)
            if !picks.isEmpty {
                grid(picks, selected: true)
                    .listRowInsets(.init(top: 12, leading: Self.margin, bottom: 16, trailing: Self.margin))
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .listRowInsets(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    .listRowSeparator(.hidden)
            }
            if hiddenCount > 0 {
                Label(
                    "\(hiddenCount) artist\(hiddenCount == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))",
                    systemImage: "eye.slash"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(.init(top: 14, leading: Self.margin + 8, bottom: 0, trailing: Self.margin))
                .listRowSeparator(.hidden)
            }
            grid(rest, selected: false)
                .listRowInsets(.init(top: 14, leading: Self.margin, bottom: 10, trailing: Self.margin))
        }
        .listStyle(.plain)
        // The separator is a 1pt row; the default minimum centres it in 44pt.
        .environment(\.defaultMinListRowHeight, 1)
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.bottom, 72, for: .scrollContent)
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
            if selected.isEmpty { selected = Self.developmentSelection }
        }
        .onDisappear { building = false }
        .task {
            guard let library = model.library else { return }
            switch kind {
            case .artist: artists = (try? await library.artists(inSection: section.key)) ?? []
            case .album: albums = (try? await library.albums(inSection: section.key)) ?? []
            }
            loaded = true
            #if DEBUG
            // `picks` here is the body's shadow, frozen at first render.
            if ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil, !self.picks.isEmpty {
                play()
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

    private func grid(_ items: [Item], selected isSelected: Bool) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                Button { toggle(item.id) } label: {
                    MixTile(kind: kind, item: item, selected: isSelected, url: model.library?.artworkURL(item.thumb))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Remove \(item.title)" : "Add \(item.title)")
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

    /// Every track across the selection, fetched concurrently, shuffled once
    /// at enqueue time like Shuffle Favorites.
    private func play() {
        guard let library = model.library, !loadingMix else { return }
        let keys = picks.map(\.id)
        guard !keys.isEmpty else { return }
        loadingMix = true
        Task {
            defer { loadingMix = false }
            let kind = kind
            let section = section.key
            let tracks = await withTaskGroup(of: [PlexTrack].self) { group in
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
            let playable = tracks.filter { !hidden.contains($0.grandparentRatingKey ?? "") }
            guard !playable.isEmpty else {
                nothingToPlay = true
                return
            }
            player.play(playable.shuffled(), startingAt: 0, library: library)
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
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color(.label), in: .circle)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
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
            .contentShape(.rect)
        }

        @ViewBuilder private var art: some View {
            switch kind {
            case .artist:
                Artwork(url: url, size: nil, corner: 8)
                    .clipShape(.circle)
                    .overlay {
                        if selected {
                            Circle().stroke(kind.accent, lineWidth: 2)
                        }
                    }
            case .album:
                Artwork(url: url, size: nil, corner: 8)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 8).stroke(kind.accent, lineWidth: 2)
                        }
                    }
            }
        }
    }
}

/// The one action on the page, styled like Shuffle Favorites on the root.
/// Reads as a prompt until something is picked.
private struct PlayMixCard: View {
    let kind: MixKind
    let picks: [String]
    let loading: Bool
    let action: () -> Void

    private var empty: Bool { picks.isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(kind.accent))
                    .frame(width: 44, height: 44)
                    .background(empty ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(kind.accent.opacity(0.14)), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(empty ? "Build a mix" : "Play Mix")
                        .font(.headline)
                        .foregroundStyle(empty ? .secondary : .primary)
                    Text(empty ? "Tap \(kind.noun) below to build a mix" : picks.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: "shuffle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(empty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(kind.accent))
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(loading || empty)
        .animation(.snappy, value: empty)
    }
}
