import PlexKit
import SwiftUI

/// One playlist as a list of track rows under Play and Shuffle, the
/// Favorites page's shape rather than the album page's: it is tracks
/// from many albums, and edit mode (reorder, swipe to remove) is a `List`
/// feature. Playing it skips what the active listeners hide by any veto,
/// and the hidden line says how many rows that is. A regular playlist
/// edits in place, optimistically, and reloads when the server refuses;
/// a smart playlist is the server's and shows no edit affordance.
struct PlaylistView: View {
    let model: AppModel
    /// The entry as pushed. The title and counts are read live from the
    /// model's list, since a rename lands there first.
    let playlist: PlexPlaylist
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.dismiss) private var dismiss

    @State private var items: [PlaylistItem] = []
    @State private var loaded = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @State private var scrollPosition = ScrollPosition()
    @State private var editMode: EditMode = .inactive

    private var offline: Bool { model.library?.isOffline ?? false }
    private var hidden: VetoSet { model.roster.hidden }
    private var current: PlexPlaylist { model.playlists.first { $0.id == playlist.id } ?? playlist }
    /// Regular and online: the rows reorder and remove.
    private var editable: Bool { !current.smart && !offline }

    /// One row of the page, keyed by the item id where the server gives
    /// one and by position on a smart playlist, whose items have none.
    private struct Row: Identifiable {
        let id: String
        let item: PlaylistItem
        var track: PlexTrack { item.track }
    }

    private var tracks: [PlexTrack] { items.map(\.track) }
    /// The rows: what no veto hides, in the playlist's order.
    private var rows: [Row] {
        items.enumerated().compactMap { index, item in
            guard !hidden.hides(item.track) else { return nil }
            return Row(id: item.playlistItemID.map { "item:\($0)" } ?? "pos:\(index)", item: item)
        }
    }
    /// Offline, only rows with a file are worth queueing.
    private var playableRows: [Row] {
        offline ? rows.filter { model.downloads.isAvailable($0.track) } : rows
    }
    private var playable: [PlexTrack] { playableRows.map(\.track) }
    private var hiddenCount: HiddenCount { .over(tracks, hidden: hidden) }

    private static let margin: CGFloat = 16

    var body: some View {
        list
            .artworkBackground(model.library?.artworkURL(current.composite, size: 900))
            .overlay { emptyState }
            .navigationTitle(current.title)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            // Keyed on both generations: going offline, or coming back,
            // reloads from whichever library is current, and an add from
            // another screen's menu lands here too.
            .task(id: Reload(library: model.libraryGeneration, playlists: model.playlistGeneration)) {
                await load()
                await developmentHooks()
            }
            .refreshable { await load() }
            // Deleted, here or elsewhere: the page has nothing left to show.
            .onChange(of: model.playlistGeneration) { _, _ in
                if !offline, !model.playlists.contains(where: { $0.id == playlist.id }) { dismiss() }
            }
    }

    private var list: some View {
        let rows = rows
        let siblings = rows.map(\.track)
        return List {
            header
            ForEach(rows) { row in
                self.row(row, siblings: siblings)
                    .listRowBackground(Color.clear)
            }
            .onMove(perform: moveHandler)
            .onDelete(perform: deleteHandler)
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
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
    }

    @ViewBuilder private var emptyState: some View {
        if !loaded {
            ProgressView()
        } else if items.isEmpty {
            let title: String = current.smart ? "Nothing matches yet" : "No tracks yet"
            let detail: String = current.smart
                ? "This smart playlist's filter finds nothing right now."
                : "Tap ··· on a track, album or artist and choose Add to Playlist."
            ContentUnavailableView(title, systemImage: "music.note.list", description: Text(detail))
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        // The page's own menu, like the album and artist pages: the
        // queue items, Rename and Delete, the offline pin. Declared
        // first so it sits leftmost, ahead of the icons.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                PlaylistMenu(model: model, playlist: current, items: items, showPlaylist: false)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        if editable, !items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                let title: String = editMode.isEditing ? "Done" : "Edit"
                Button(title) {
                    withAnimation(.snappy) { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
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

    /// `CTUNES_DEV_PIN=playlist` pins the page once it loads, so the
    /// files under Application Support and the badge can be checked in a
    /// simulator; `CTUNES_DEV_SCROLL` scrolls, as on every page.
    private func developmentHooks() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CTUNES_DEV_PIN"] == "playlist", !offline, !items.isEmpty,
           !model.downloads.isPinned(current) {
            await model.setPlaylistPinned(current, true)
        }
        if let y = ProcessInfo.processInfo.environment["CTUNES_DEV_SCROLL"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(1))
            scrollPosition.scrollTo(y: y)
        }
        #endif
    }

    /// What the fetch is keyed on.
    private struct Reload: Hashable {
        let library: Int
        let playlists: Int
    }

    /// The cards, the rule and the hidden line, as list rows that edit
    /// mode leaves alone.
    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            MixActionCard(systemImage: "play.fill", title: "Play", subtitle: nil,
                          enabled: !playable.isEmpty, loading: false, tint: nil, action: play)
            MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                          enabled: !playable.isEmpty, loading: false, tint: nil, action: shuffle)
        }
        .listRowInsets(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
        .deleteDisabled(true)
        Rectangle()
            .fill(Color.divider)
            .frame(height: 1)
            .listRowInsets(.init(top: 0, leading: Self.margin, bottom: 0, trailing: Self.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
            .deleteDisabled(true)
        HiddenLine(model: model, count: hiddenCount)
            .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
            .deleteDisabled(true)
    }

    /// The fetch: on appear, on either generation, and on pull to
    /// refresh. Online, the items are remembered for offline.
    private func load() async {
        guard let library = model.library else { return }
        do {
            items = try await library.items(inPlaylist: playlist.ratingKey)
        } catch {
            await model.connectionLost(error)
            if model.library?.isOffline != true { items = [] }
            return
        }
        loaded = true
        if items.isEmpty { editMode = .inactive }
        await model.rememberItems(items, inPlaylist: current)
        for thumb in Set(items.compactMap(\.track.thumb)) {
            ImageLoader.shared.prewarm(library.artworkURL(thumb))
        }
    }

    /// "12 tracks · 48 min" over the rows; a smart playlist says so, since
    /// it can't be edited and the absence deserves a word.
    private var subtitle: String {
        guard loaded else { return "" }
        var parts = [PlexPlaylist.trackCount(rows.count)]
        let length = rows.reduce(0) { $0 + ($1.track.duration ?? 0) }
        if length > 0 { parts.append(PlexPlaylist.length(milliseconds: length)) }
        if current.smart { parts.insert("Smart playlist", at: 0) }
        return parts.joined(separator: " · ")
    }

    private func row(_ row: Row, siblings: [PlexTrack]) -> some View {
        let track = row.track
        let downloaded = model.downloads.isDownloaded(track)
        let downloading = !downloaded && model.downloads.isDownloading(track)
        // Offline, a row with no file has nothing to play; a file left in
        // the cache root from an earlier play counts.
        let playable = !offline || model.downloads.isAvailable(track)
        let placement = TrackPlacement.playlistItem(row.item, in: current, siblings: siblings)
        // The ··· sits beside the tappable part rather than inside it, so
        // its tap is never also a tap on the row.
        return HStack(spacing: 4) {
            Button {
                guard let library = model.library, playable else { return }
                let queue = playableRows
                let start = queue.firstIndex { $0.id == row.id } ?? 0
                player.play(queue.map(\.track), startingAt: start, library: library)
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
            if !editMode.isEditing {
                MoreButton { TrackMenu(model: model, track: track, placement: placement) }
            }
        }
        .listRowInsets(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
        .contextMenu { TrackMenu(model: model, track: track, placement: placement) }
        // Pruning a regular playlist deserves the shortcut, as the hearts
        // do on Favorites. Edits are refused offline.
        .swipeActions(edge: .trailing) {
            if editable, row.item.playlistItemID != nil {
                Button(role: .destructive) {
                    remove([row.item])
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Edits

    /// Nil on a smart playlist or offline, which also hides the edit
    /// controls the `List` would otherwise offer.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        editable ? { moveRows(from: $0, to: $1) } : nil
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        editable ? { removeRows(at: $0) } : nil
    }

    /// Reorders the rows at once and tells the server where the item now
    /// sits: after the row above it, or at the top. The rows leave out
    /// what a veto hides, so the item goes into `items` right after that
    /// row's item rather than at the row's offset.
    private func moveRows(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let rows = rows
        var reordered = rows
        reordered.move(fromOffsets: source, toOffset: destination)
        let moved = rows[from]
        guard let at = reordered.firstIndex(where: { $0.id == moved.id }) else { return }
        let above = at > 0 ? reordered[at - 1].item : nil
        var updated = items
        updated.removeAll { $0.playlistItemID == moved.item.playlistItemID }
        if let above, let index = updated.firstIndex(where: { $0.playlistItemID == above.playlistItemID }) {
            updated.insert(moved.item, at: index + 1)
        } else {
            updated.insert(moved.item, at: 0)
        }
        items = updated
        Task {
            if await !model.move(moved.item, after: above, in: current) { await load() }
        }
    }

    private func removeRows(at offsets: IndexSet) {
        remove(offsets.map { rows[$0].item })
    }

    /// Drops the rows at once and removes each on the server; the first
    /// refusal reloads the page.
    private func remove(_ doomed: [PlaylistItem]) {
        let ids = Set(doomed.compactMap(\.playlistItemID))
        guard !ids.isEmpty else { return }
        items.removeAll { $0.playlistItemID.map(ids.contains) ?? false }
        Task {
            for item in doomed {
                if await !model.remove(item, from: current) {
                    await load()
                    return
                }
            }
        }
    }

    // MARK: - Playback

    private func play() {
        guard let library = model.library, !playable.isEmpty else { return }
        player.play(playable, startingAt: 0, library: library)
        nowPlaying.isShown = true
    }

    /// The same spread shuffle as everywhere else, over the same rows.
    private func shuffle() {
        guard let library = model.library, !playable.isEmpty else { return }
        player.play(playable.spreadShuffled(), startingAt: 0, library: library)
        nowPlaying.isShown = true
    }
}
