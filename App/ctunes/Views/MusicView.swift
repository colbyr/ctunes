import PlexKit
import SwiftUI

/// Browse root: every album in the library, sorted and grouped however the
/// arrange button last left it. The query from the floating search pill switches to
/// a flat grid ranked by match quality.
struct MusicView: View {
    let model: AppModel
    let section: PlexSection
    @Binding var query: String
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player

    @State private var albums: [PlexAlbum] = []
    /// Fetched with the albums so the shuffle card can say how many tracks
    /// it would play; nil until the request lands.
    @State private var favorites: [PlexTrack]?
    @State private var loaded = false
    @State private var loadingFavorites = false
    @State private var noFavorites = false
    @State private var everyFavoriteHidden = false
    @State private var showingListeners = false
    @AppStorage("albumSort") private var sort: AlbumSort = .recentlyAdded
    @AppStorage("albumGrouping") private var grouping: AlbumGrouping = .artist

    private var hidden: Set<String> { model.roster.hiddenArtistKeys }
    private var groups: [AlbumGroup] {
        AlbumBrowse.groups(albums, sort: sort, grouping: grouping, hiding: hidden)
    }
    private var results: [PlexAlbum] {
        AlbumBrowse.search(albums, query: query, sort: sort, hiding: hidden)
    }
    /// Every artist in the library, for the listeners sheet and the count
    /// under the title. Unfiltered, so a veto from another section doesn't
    /// count here.
    private var artists: [AlbumGroup] {
        AlbumBrowse.groups(albums, sort: .name, grouping: .artist)
    }
    private var hiddenCount: Int { artists.filter { hidden.contains($0.id) }.count }

    /// Tiles push onto the path by hand: a NavigationLink in a List row makes
    /// the whole row a link too, so one tap pushed two albums and back landed
    /// on the wrong one.
    private func grid(_ albums: [PlexAlbum], minimum: CGFloat, spacing: CGFloat, showArtist: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) {
            ForEach(albums) { album in
                Button { path.append(album) } label: {
                    AlbumTile(model: model, album: album, showArtist: showArtist)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Matches the nav bar's large title and the bottom pills.
    private static let margin: CGFloat = 16

    var body: some View {
        List {
            if !query.isEmpty {
                grid(results, minimum: 100, spacing: 12, showArtist: true)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 8, trailing: Self.margin))
            } else {
                // One row for all three cards: the row clips at its insets,
                // so the shadow between the cards needs no inset at all and
                // only the outer edges have to clear it.
                VStack(spacing: 12) {
                    ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites)
                    HStack(spacing: 12) {
                        MixTile(kind: .artist) { path.append(MixKind.artist) }
                        MixTile(kind: .album) { path.append(MixKind.album) }
                    }
                }
                .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                .listRowSeparator(.hidden)
                // The browser starts here: a rule, then the chips with the
                // arrange button, then the hidden-artist line when any are.
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                AlbumBrowserControls(model: model, grouping: $grouping, sort: $sort)
                    .listRowInsets(.init(top: 16, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                if hiddenCount > 0 {
                    HiddenArtistsLine(model: model, count: hiddenCount)
                        .listRowInsets(.init(top: 12, leading: Self.margin + 8, bottom: 0, trailing: Self.margin))
                        .listRowSeparator(.hidden)
                }
                ForEach(groups) { group in
                    Section {
                        grid(group.albums, minimum: 100, spacing: 12, showArtist: grouping != .artist)
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
                }
            }
        }
        .listStyle(.plain)
        // The rule is a 1pt row; the default minimum centres it in 44pt.
        .environment(\.defaultMinListRowHeight, 1)
        // The row insets set the gaps; the default section gap on top of
        // them left too much air above each group title.
        .listSectionSpacing(0)
        // The collapsed title and subtitle sit over artwork once you scroll;
        // the soft edge effect leaves the subtitle hard to read.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollDismissesKeyboard(.immediately)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            } else if !query.isEmpty && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Tunes")
        // Always present so the title doesn't jump when listeners toggle.
        .navigationSubtitle(hiddenCount > 0
            ? "\(hiddenCount) artist\(hiddenCount == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))"
            : "Everything")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Listeners…", systemImage: "person.2") { showingListeners = true }
                    if model.sections.count > 1 {
                        Button("Change library") { model.clearSectionChoice() }
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            guard let library = model.library else { return }
            async let favoriteTracks = library.favoriteTracks(inSection: section.key)
            albums = (try? await library.albums(inSection: section.key)) ?? []
            loaded = true
            favorites = try? await favoriteTracks
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] != nil {
                showingListeners = true
            }
            #endif
        }
        .alert("No favorites yet", isPresented: $noFavorites) {
            Button("OK") {}
        } message: {
            Text("Swipe a track left, or tap the heart in Now Playing, to favorite it.")
        }
        .alert("Nothing to shuffle", isPresented: $everyFavoriteHidden) {
            Button("OK") {}
        } message: {
            Text("Every favorite is by an artist hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name))).")
        }
        .sheet(isPresented: $showingListeners) {
            ListenersSheet(model: model, artists: artists)
        }
    }

    /// "32 tracks for you & Laura"; just the count with no listeners set up,
    /// just the listeners until the count arrives, nothing with neither.
    private var favoritesSubtitle: String? {
        let names = model.roster.active.map(\.name)
        let who = model.roster.listeners.isEmpty
            ? nil
            : "for " + (names.isEmpty ? "just you" : ListenerRoster.joinNames(["you"] + names))
        let count = favorites.map { allowed($0).count }
            .map { "\($0) track\($0 == 1 ? "" : "s")" }
        let parts = [count, who].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func allowed(_ tracks: [PlexTrack]) -> [PlexTrack] {
        tracks.filter { !hidden.contains($0.grandparentRatingKey ?? "") }
    }

    /// Every favorite track in the library, in a fresh random order each tap.
    /// Spread-shuffling once at enqueue time is all this needs; the player has
    /// no shuffle mode of its own.
    private func shuffleFavorites() {
        guard let library = model.library, !loadingFavorites else { return }
        loadingFavorites = true
        Task {
            defer { loadingFavorites = false }
            // Fetched fresh rather than reusing the count's copy: hearts may
            // have been toggled since the screen loaded.
            let fetched = (try? await library.favoriteTracks(inSection: section.key)) ?? []
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
        }
    }
}

private struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .artworkShadow()
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(showArtist ? (album.parentTitle ?? "—") : (album.year.map(String.init) ?? "—"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// Sits above the grid as a raised card so it reads as the one action on
/// the page rather than another row.
private struct ShuffleFavoritesCard: View {
    let subtitle: String?
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(.pink)
                    .frame(width: 44, height: 44)
                    .background(.pink.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle Favorites").font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: "shuffle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.pink)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .cardShadow()
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }
}

/// Half-width entry to a mix builder, sharing the hero card's chrome.
private struct MixTile: View {
    let kind: MixKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(kind.accent)
                    .frame(width: 36, height: 36)
                    .background(kind.accent.opacity(0.14), in: .circle)
                Text(kind.title).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .cardShadow()
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
