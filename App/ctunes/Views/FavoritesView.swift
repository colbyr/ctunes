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
        case .recent: "Recently Hearted"
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
    @State private var confirmingUnpin = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
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
                              enabled: !playable.isEmpty, loading: false, action: play)
                MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                              enabled: !playable.isEmpty, loading: false, action: shuffle)
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
                HStack(spacing: 8) {
                    Button(action: toggleOffline) {
                        // Ink by name: a ternary with a Color turns `.primary`
                        // into `Color.primary`, the system white, rather than
                        // the hierarchical style that inherits the app's ink.
                        Image(systemName: model.isFavoritesPinned ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(model.isFavoritesPinned ? Color.accentText : Color.ink)
                            .frame(width: 34, height: 34)
                            .background(.fill.tertiary, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(offline)
                    .accessibilityLabel(model.isFavoritesPinned ? "Kept offline, tap to stop" : "Keep offline")
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
        .environment(\.defaultMinListRowHeight, 1)
        .listSectionSpacing(0)
        .scrollEdgeEffectStyle(.hard, for: .top)
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
                                       description: Text("Swipe a track left, or tap the heart in Now Playing, to favorite it."))
            }
        }
        .navigationTitle("Favorites")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .confirmationDialog("Stop keeping favorites offline?", isPresented: $confirmingUnpin, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                Task { await model.setFavoritesPinned(false) }
            }
        } message: {
            Text("Your favorites stay hearted and will stream again. Albums you downloaded on their own are kept.")
        }
    }

    private var subtitle: String {
        let count = rows.count
        return loaded ? "\(count) track\(count == 1 ? "" : "s")" : ""
    }

    private func row(_ track: PlexTrack, at index: Int) -> some View {
        let downloaded = model.downloads.isPinned(track)
        // Offline, a row with no file has nothing to play; a file left in
        // the cache root from an earlier play counts.
        let playable = !offline || model.downloads.isAvailable(track)
        return Button {
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
                // shift as files come and go.
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(downloaded ? 1 : 0)
                    .accessibilityHidden(!downloaded)
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
        .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { enqueue([track], next: true) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(ListenerPalette.clay)
            Button { enqueue([track], next: false) } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(ListenerPalette.slate)
        }
        .swipeActions(edge: .trailing) {
            // Hearts are read-only offline.
            if !offline {
                Button {
                    Task { await model.toggleFavorite(track) }
                } label: {
                    Label("Unfavorite", systemImage: "heart.slash")
                }
                .tint(Color.accentText)
            }
        }
    }

    private func toggleOffline() {
        guard !offline else { return }
        if model.isFavoritesPinned {
            confirmingUnpin = true
        } else {
            Task { await model.setFavoritesPinned(true) }
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

    private func enqueue(_ tracks: [PlexTrack], next: Bool) {
        guard let library = model.library else { return }
        let tracks = offline ? tracks.filter { model.downloads.isAvailable($0) } : tracks
        guard !tracks.isEmpty else { return }
        next ? player.playNext(tracks, library: library)
             : player.addToQueue(tracks, library: library)
    }
}
