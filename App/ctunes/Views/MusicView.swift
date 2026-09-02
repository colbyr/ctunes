import PlexKit
import SwiftUI

/// Browse root: every album in the library, sorted and grouped however the
/// ⋯ menu last left it. The query from the floating search pill switches to
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
                if !model.roster.listeners.isEmpty {
                    ListenerChips(model: model)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
                ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 12, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                ForEach(groups) { group in
                    Section {
                        grid(group.albums, minimum: 100, spacing: 12, showArtist: grouping != .artist)
                            .listRowInsets(.init(top: 4, leading: Self.margin, bottom: 10, trailing: Self.margin))
                    } header: {
                        if !group.name.isEmpty {
                            Text(group.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .textCase(nil)
                                // A touch past the grid: text flush with the
                                // artwork edge reads as misaligned.
                                .padding(.leading, Self.margin + 8)
                                .padding(.vertical, 6)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
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
                    Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $sort) {
                        ForEach(AlbumSort.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.menu)
                    Picker("Group By", systemImage: "square.grid.2x2", selection: $grouping) {
                        ForEach(AlbumGrouping.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.menu)
                    Divider()
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
    /// Shuffling once at enqueue time is all this needs; the player has no
    /// shuffle mode of its own.
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
            player.play(playable.shuffled(), startingAt: 0, library: library)
        }
    }
}

/// Who's in the car. The owner is always in; each listener toggles.
private struct ListenerChips: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Chip(active: true) {
                        OwnerAvatar()
                        Text("You")
                    }
                    ForEach(model.roster.listeners) { listener in
                        let active = model.roster.isActive(listener.id)
                        Button {
                            withAnimation(.snappy) { model.toggleListening(listener.id) }
                        } label: {
                            Chip(active: active) {
                                ListenerAvatar(listener: listener).opacity(active ? 1 : 0.45)
                                Text(listener.name)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(active ? "\(listener.name) is listening" : "\(listener.name) is not listening")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
        .padding(.vertical, 4)
    }

    private struct Chip<Content: View>: View {
        let active: Bool
        @ViewBuilder let content: Content

        var body: some View {
            HStack(spacing: 7) { content }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.secondary))
                .padding(.leading, 5)
                .padding(.trailing, 14)
                .frame(height: 34)
                .background(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.background), in: .capsule)
                .contentShape(.capsule)
        }
    }
}

private struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
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
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }
}
