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
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Bytes of cached audio, for the clear button; nil until read.
    @State private var cacheUsage: Int?
    @State private var confirmingRemoveAll = false
    @AppStorage("albumView") private var view: AlbumView = .recentlyAdded
    @AppStorage("albumDownloadedOnly") private var downloadedOnly = false

    private var offline: Bool { model.state == .offline }
    private var hidden: Set<String> { model.roster.hiddenArtistKeys }
    /// Filtered before the pure grouping and search, so those stay pure.
    /// Anything with a file to play, so an album still downloading shows.
    private var browsable: [PlexAlbum] {
        downloadedOnly ? albums.filter { model.downloads.hasDownloads($0) } : albums
    }
    private var groups: [AlbumGroup] {
        AlbumBrowse.groups(browsable, view: view, hiding: hidden)
    }
    private var results: [PlexAlbum] {
        AlbumBrowse.search(browsable, query: query, view: view, hiding: hidden)
    }
    /// Every artist in the library, for the listeners sheet and the count
    /// under the title. Unfiltered, so a veto from another section doesn't
    /// count here.
    private var artists: [AlbumGroup] {
        AlbumBrowse.groups(albums, view: .artist)
    }
    private var hiddenCount: Int { artists.filter { hidden.contains($0.id) }.count }

    /// Tiles push onto the path by hand: a NavigationLink in a List row makes
    /// the whole row a link too, so one tap pushed two albums and back landed
    /// on the wrong one.
    private func grid(_ albums: [PlexAlbum], spacing: CGFloat, showArtist: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) {
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
    /// Three across on a phone; on an iPad the same minimum gave nine tiny
    /// tiles, so the floor rises to keep the covers legible.
    private var tileMinimum: CGFloat { sizeClass == .regular ? 150 : 100 }

    var body: some View {
        List {
            if !query.isEmpty {
                grid(results, spacing: 12, showArtist: true)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 8, trailing: Self.margin))
                    .listRowBackground(Color.clear)
            } else {
                if offline {
                    OfflineBanner(reconnecting: model.reconnecting) {
                        Task { await model.reconnect(force: true) }
                    }
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 4, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                // One row for all three cards: the row clips at its insets,
                // so the shadow between the cards needs no inset at all and
                // only the outer edges have to clear it.
                // Stacked on a phone; one row of three on a wider screen,
                // where a full-width hero card is mostly empty.
                if sizeClass == .regular {
                    HStack(spacing: 12) {
                        ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites)
                        MixTile(kind: .artist) { path.append(MixKind.artist) }
                        MixTile(kind: .album) { path.append(MixKind.album) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    VStack(spacing: 12) {
                        ShuffleFavoritesCard(subtitle: favoritesSubtitle, loading: loadingFavorites, action: shuffleFavorites)
                        HStack(spacing: 12) {
                            MixTile(kind: .artist) { path.append(MixKind.artist) }
                            MixTile(kind: .album) { path.append(MixKind.album) }
                        }
                    }
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                // The browser starts here: a rule, then the chips with the
                // arrange button, then the hidden-artist line when any are.
                Rectangle()
                    .fill(Color.divider)
                    .frame(height: 1)
                    .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                AlbumBrowserControls(model: model, view: $view, downloadedOnly: $downloadedOnly)
                    .listRowInsets(.init(top: 16, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                HiddenArtistsLine(model: model, count: hiddenCount)
                    .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                // In the list rather than an overlay, so it sits under the
                // cards and the controls instead of over them.
                if loaded, !albums.isEmpty, groups.isEmpty, downloadedOnly {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Turn off Downloaded only to see the whole library."))
                        .listRowInsets(.init(top: 32, leading: Self.margin, bottom: 0, trailing: Self.margin))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in
                    Section {
                        grid(group.albums, spacing: 12, showArtist: view != .artist)
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
            }
        }
        .listStyle(.plain)
        .parchment()
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
        .contentMargins(.bottom, 84, for: .scrollContent)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Listeners…", systemImage: "person.2") { showingListeners = true }
                    if model.sections.count > 1, !offline {
                        Button("Change library") { model.clearSectionChoice() }
                    }
                    Section("Downloads") {
                        Toggle("Keep favorites offline", systemImage: "heart", isOn: Binding(
                            get: { model.isFavoritesPinned },
                            set: { on in Task { await model.setFavoritesPinned(on) } }
                        ))
                        .disabled(offline)
                        if model.downloads.usage > 0 {
                            Text("Downloads: \(Self.bytes(model.downloads.usage))")
                            Button("Remove all downloads", systemImage: "trash", role: .destructive) {
                                confirmingRemoveAll = true
                            }
                        }
                        if let cacheUsage, cacheUsage > 0 {
                            Button("Clear cached tracks (\(Self.bytes(cacheUsage)))", systemImage: "trash") {
                                Task {
                                    await player.clearCache()
                                    self.cacheUsage = await player.cacheUsage()
                                }
                            }
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Re-read as the queue moves, since every track played adds a file.
        .task(id: player.currentTrack?.id) {
            cacheUsage = await player.cacheUsage()
        }
        // Keyed on the generation so going offline, or coming back, reloads
        // from whichever library is current.
        .task(id: model.libraryGeneration) {
            guard let library = model.library else { return }
            do {
                async let favoriteTracks = library.favoriteTracks(inSection: section.key)
                albums = try await library.albums(inSection: section.key)
                loaded = true
                favorites = try? await favoriteTracks
            } catch {
                await model.connectionLost(error)
                loaded = true
                return
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] != nil {
                showingListeners = true
            }
            #endif
            if !library.isOffline {
                await model.snapshot(albums: albums, favorites: favorites ?? [])
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { model.downloads.removeAll() }
        } message: {
            Text("Pinned albums and favorites will stream again. Nothing is removed from your library.")
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

    /// Offline, also only tracks with a file: an unplayable track must
    /// never enter the queue.
    private func allowed(_ tracks: [PlexTrack]) -> [PlexTrack] {
        tracks.filter {
            !hidden.contains($0.grandparentRatingKey ?? "") && (!offline || model.downloads.isAvailable($0))
        }
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
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
            nowPlaying.isShown = true
        }
    }
}

private struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool

    var body: some View {
        let downloaded = model.downloads.isDownloaded(album)
        let playable = model.downloads.hasDownloads(album)
        let offline = model.state == .offline
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) {
                    if downloaded { DownloadedBadge() }
                }
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
        // Browsable but not playable: still in the grid, clearly dimmed.
        .opacity(offline && !playable ? 0.35 : 1)
        .contentShape(.rect)
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
                    .foregroundStyle(Color.accentInk)
                    .frame(width: 44, height: 44)
                    .background(Color.amber, in: .circle)
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
                        .foregroundStyle(Color.accentText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(cornerRadius: 24)
            .contentShape(.rect(cornerRadius: 24))
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
                    .foregroundStyle(Color.chipInk)
                    .frame(width: 36, height: 36)
                    .background(Color.chip, in: .circle)
                Text(kind.title).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard()
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}
