import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open the Favorites page.
struct FavoritesRoute: Hashable {}

/// How the Favorites page orders its rows. Persisted per device.
enum FavoritesSort: String, CaseIterable, Identifiable {
    case recent, artist, album

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently Favorited"
        case .artist: "Artist"
        case .album: "Album"
        }
    }

    func sorted(_ tracks: [PlexTrack]) -> [PlexTrack] {
        switch self {
        case .recent:
            // Newest heart first; tracks rated before the server kept a
            // timestamp fall to the end in whatever order they came.
            return tracks.enumerated().sorted { a, b in
                (a.element.lastRatedAt ?? -1, -a.offset) > (b.element.lastRatedAt ?? -1, -b.offset)
            }.map(\.element)
        case .artist:
            return tracks.sorted {
                (Self.name($0.grandparentTitle), Self.name($0.parentTitle), $0.parentIndex ?? 0, $0.index ?? 0)
                    < (Self.name($1.grandparentTitle), Self.name($1.parentTitle), $1.parentIndex ?? 0, $1.index ?? 0)
            }
        case .album:
            return tracks.sorted {
                (Self.name($0.parentTitle), Self.name($0.grandparentTitle), $0.parentIndex ?? 0, $0.index ?? 0)
                    < (Self.name($1.parentTitle), Self.name($1.grandparentTitle), $1.parentIndex ?? 0, $1.index ?? 0)
            }
        }
    }

    /// Case-folded so "the national" sorts among the Ns, not after the Zs.
    private static func name(_ title: String?) -> String {
        (title ?? "").lowercased()
    }
}

/// Every favorite track in the library as one list: play it in order, shuffle
/// it the way the root card does, or prune it. Hearts toggled here drop the
/// row; the set itself is the server's ratings, never a playlist of its own.
struct FavoritesView: View {
    let model: AppModel
    let section: PlexSection
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying

    @State private var tracks: [PlexTrack] = []
    /// For the Listeners sheet's veto lists, which cover the whole library.
    @State private var albums: [PlexAlbum] = []
    @State private var loaded = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @State private var scrollPosition = ScrollPosition()
    @AppStorage("favoritesSort") private var sort: FavoritesSort = .recent

    private var offline: Bool { model.library?.isOffline ?? false }
    private var hidden: Set<String> { model.roster.hiddenArtistKeys }

    /// Still hearted as far as this session knows: an unheart from a row
    /// or Now Playing drops the track without a refetch.
    private var hearted: [PlexTrack] { tracks.filter { model.isFavorite($0) } }

    /// The rows: hearted, not by a hidden artist, in the chosen order.
    private var rows: [PlexTrack] {
        sort.sorted(hearted.filter { !hidden.contains($0.grandparentRatingKey ?? "") })
    }

    /// Offline, only tracks with a file are worth queueing.
    private var playable: [PlexTrack] {
        offline ? rows.filter { model.downloads.isAvailable($0) } : rows
    }

    private var hiddenCount: Int {
        Set(hearted.compactMap(\.grandparentRatingKey).filter { hidden.contains($0) }).count
    }

    private static let margin: CGFloat = 16

    var body: some View {
        let rows = rows
        List {
            HStack(spacing: 12) {
                MixActionCard(systemImage: "play.fill", title: "Play", subtitle: nil,
                              enabled: !playable.isEmpty, loading: false, tint: .heart, action: play)
                MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                              enabled: !playable.isEmpty, loading: false, tint: .heart, action: shuffle)
            }
            .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            Rectangle()
                .fill(Color.divider)
                .frame(height: 1)
                .listRowInsets(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            ListenerChips(model: model, artists: AlbumBrowse.groups(albums, view: .artist)) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(FavoritesSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(.fill.tertiary, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sorted by \(sort.title)")
            }
            .listRowInsets(.init(top: 16, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            HiddenArtistsLine(model: model, count: hiddenCount)
                .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, track in
                row(track, at: index)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .parchment()
        .scrollPosition($scrollPosition)
        .environment(\.defaultMinListRowHeight, 1)
        .listSectionSpacing(0)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Past the action cards (about their height plus the row insets).
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 90
        } action: { _, scrolledPast in
            withAnimation(.snappy) { actionsVisible = !scrolledPast }
        }
        .contentMargins(.bottom, 84, for: .scrollContent)
        .animation(.snappy, value: rows.map(\.id))
        .overlay {
            if !loaded {
                ProgressView()
            } else if hearted.isEmpty {
                ContentUnavailableView("No favorites yet", systemImage: "heart",
                                       description: Text("Tap ··· on a track, or the heart in Now Playing, to favorite it."))
            }
        }
        .navigationTitle("Favorites")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The page's own menu, like the album and artist pages: the
            // offline pin lives here. Read-only offline, so nothing then.
            // Declared first so it sits leftmost, ahead of the icons.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !offline {
                        if model.isFavoritesPinned {
                            Button(role: .destructive) {
                                Task { await model.setFavoritesPinned(false) }
                            } label: {
                                Label("Remove Download", systemImage: "trash")
                            }
                        } else {
                            Button {
                                Task { await model.setFavoritesPinned(true) }
                            } label: {
                                Label("Keep Offline", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(offline)
            }
            // The cards' actions follow you down the list as icons.
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Play", systemImage: "play.fill", action: play)
                        .disabled(playable.isEmpty)
                    Button("Shuffle", systemImage: "shuffle", action: shuffle)
                        .disabled(playable.isEmpty)
                }
            }
        }
        // Keyed on the generation so going offline, or coming back, reloads
        // from whichever library is current.
        .task(id: model.libraryGeneration) {
            await load()
            #if DEBUG
            if let y = ProcessInfo.processInfo.environment["CTUNES_DEV_SCROLL"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                scrollPosition.scrollTo(y: y)
            }
            #endif
        }
        .refreshable { await load() }
    }

    /// The fetch: on appear, on a library swap, and on pull to refresh.
    private func load() async {
        guard let library = model.library else { return }
        do {
            async let all = library.albums(inSection: section.key)
            tracks = try await library.favoriteTracks(inSection: section.key)
            albums = (try? await all) ?? []
        } catch {
            await model.connectionLost(error)
            if model.library?.isOffline != true { tracks = [] }
            return
        }
        loaded = true
        for thumb in Set(tracks.compactMap(\.thumb)) {
            ImageLoader.shared.prewarm(library.artworkURL(thumb))
        }
    }

    private var subtitle: String {
        let count = rows.count
        return loaded ? "\(count) track\(count == 1 ? "" : "s")" : ""
    }

    private func row(_ track: PlexTrack, at index: Int) -> some View {
        let downloaded = model.downloads.isDownloaded(track)
        let downloading = !downloaded && model.downloads.isDownloading(track)
        // Offline, a row with no file has nothing to play; a file left in
        // the cache root from an earlier play counts.
        let playable = !offline || model.downloads.isAvailable(track)
        // The ··· sits beside the tappable part rather than inside it, so
        // its tap is never also a tap on the row.
        return HStack(spacing: 4) {
            Button {
                guard let library = model.library, playable else { return }
                player.play(rows, startingAt: index, library: library)
                nowPlaying.isShown = true
            } label: {
                HStack(spacing: 12) {
                    Artwork(url: model.library?.artworkURL(track.thumb), size: 44, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .lineLimit(1)
                        Text([track.trackArtist ?? track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " — "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Keeps its slot when off, so the duration column doesn't
                    // shift as files come and go. Dotted while a pin is
                    // still fetching the file.
                    Image(systemName: downloading ? "arrow.down.circle.dotted" : "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(downloaded || downloading ? 1 : 0)
                        .accessibilityHidden(!(downloaded || downloading))
                    if let seconds = track.durationSeconds {
                        Text(TracksView.duration(seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(playable ? 1 : 0.35)
            .foregroundStyle(player.currentTrack?.id == track.id ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.primary))
            MoreButton { TrackMenu(model: model, track: track, placement: .list(siblings: rows)) }
        }
        .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
        .contextMenu { TrackMenu(model: model, track: track, placement: .list(siblings: rows)) }
        // The one swipe left in the app: this list is the hearts, so
        // pruning it deserves the shortcut. Hearts are read-only offline.
        .swipeActions(edge: .trailing) {
            if !offline {
                Button {
                    Task { await model.toggleFavorite(track) }
                } label: {
                    Label("Unfavorite", systemImage: "heart.slash")
                }
                .tint(Color.heart)
            }
        }
    }

    private func play() {
        guard let library = model.library, !playable.isEmpty else { return }
        player.play(playable, startingAt: 0, library: library)
        nowPlaying.isShown = true
    }

    /// The same spread shuffle as the root card, over the same set.
    private func shuffle() {
        guard let library = model.library, !playable.isEmpty else { return }
        player.play(playable.spreadShuffled(), startingAt: 0, library: library)
        nowPlaying.isShown = true
    }

}
