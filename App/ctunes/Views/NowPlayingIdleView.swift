import PlexKit
import SwiftUI

/// The Now Playing column with nothing playing: the last session's queue
/// to pick up (`AudioPlayer.isRestored`), then a few albums to start
/// instead, listed plainly: one of the most played, one at random and
/// one played longest ago, never a single. Without the column it is what the
/// mini player opens while its Resume shows (`PresentedNowPlaying`).
/// Nothing here repeats the mix band beside it in the
/// browser, and AirPlay is the strip's.
struct NowPlayingIdleView: View {
    let model: AppModel
    let catalog: LibraryCatalog
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryNavigator.self) private var navigator

    /// The albums on offer by slot, kept while they stay allowed.
    @State private var slots: [Slot: PlexAlbum] = [:]
    /// The albums on offer, in slot order.
    private var picks: [PlexAlbum] { Slot.allCases.compactMap { slots[$0] } }
    /// The album whose tracks are being fetched, for its row's spinner.
    @State private var starting: String?

    /// Nothing answers: only downloads are offered. Not while the server
    /// is still being looked for at launch, which would leave the rows
    /// empty for the first seconds of every launch.
    private var offline: Bool { model.connection == .unreachable }

    /// What may be offered: albums of some length, nothing the active
    /// listeners hide, and offline only what is downloaded whole.
    private var candidates: [PlexAlbum] {
        let hidden = model.roster.hidden
        return catalog.albums.filter { album in
            guard (album.leafCount ?? 0) >= Self.minimumTracks, !hidden.hides(album) else { return false }
            guard offline else { return true }
            if case .complete = model.downloads.state(album) { return true }
            return false
        }
    }

    /// Fewer tracks than this is a single.
    private static let minimumTracks = 4
    /// Played more recently than this is never offered.
    private static let recentlyPlayed: TimeInterval = 7 * 86_400

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if player.isRestored, let track = player.currentTrack {
                    resumeSection(track)
                }
                startSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .artworkBackground(player.isRestored ? model.library?.artworkURL(player.currentTrack?.thumb, size: 900) : nil)
        // Picked once the catalog lands, again when it changes under a
        // pick (a veto, going offline), never on every redraw.
        .task(id: PickInputs(revision: catalog.revision, offline: offline, hidden: model.roster.hidden)) {
            choose()
        }
    }

    // MARK: - Resume

    private func resumeSection(_ track: PlexTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick Up Where You Left Off")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    Artwork(url: model.library?.artworkURL(track.thumb, size: 400), size: 96, corner: 10)
                        .artworkShadow()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.parentTitle ?? track.title)
                            .font(.title3.bold())
                            .lineLimit(2)
                        if let artist = track.grandparentTitle {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(resumeDetail(track))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: min(player.currentTime, player.duration), total: max(player.duration, 1))
                    .tint(Color.ink.opacity(0.6))
                Button {
                    player.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.accentInk)
                        .background(Color.amber, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .glassCard()
        }
    }

    /// "4 of 12 · "Lilac" at 1:42 · Yesterday".
    private func resumeDetail(_ track: PlexTrack) -> String {
        var parts: [String] = []
        let count = player.queue.entries.count
        if count > 1 { parts.append("\(player.queue.currentIndex + 1) of \(count)") }
        let at = player.currentTime >= 1 ? " at \(TracksView.duration(player.currentTime))" : ""
        parts.append("“\(track.title)”\(at)")
        if let saved = player.restoredSavedAt { parts.append(Self.when(saved)) }
        return parts.joined(separator: " · ")
    }

    /// "Today", "Yesterday", then "3 days ago", "Last month".
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let text = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Start something

    @ViewBuilder private var startSection: some View {
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start Something New")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(picks) { album in
                    row(album)
                }
            }
        }
    }

    private func row(_ album: PlexAlbum) -> some View {
        Button {
            Task { await start(album) }
        } label: {
            HStack(spacing: 14) {
                Artwork(url: model.library?.artworkURL(album.thumb, size: 200), size: 56, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let artist = album.parentTitle {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let note = lastPlayed(album) {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if starting == album.ratingKey { ProgressView() }
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(starting != nil)
        .glassCard()
        .contextMenu { AlbumMenu(model: model, album: album) }
    }

    private func lastPlayed(_ album: PlexAlbum) -> String? {
        guard let last = album.lastViewedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(last))
        return "Played " + date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    // MARK: - Picking

    private struct PickInputs: Equatable {
        let revision: Int
        let offline: Bool
        let hidden: VetoSet
    }

    /// The three kinds of pick, one row each, in this order.
    private enum Slot: CaseIterable {
        /// The head of On Rotation.
        case favorite
        /// Anything at all.
        case random
        /// Played once, at the foot of On Rotation.
        case forgotten

        /// Filled before `random`, which can take anything: in a library
        /// of two albums the slots with a rule get first refusal.
        static let fillOrder: [Slot] = [.favorite, .forgotten, .random]
    }

    /// Keeps the picks that are still allowed, so a row doesn't change
    /// under the finger, and fills the slots left empty. Nothing played
    /// this past week, in any slot: that is still in the ear.
    private func choose() {
        let pool = candidates
        let keys = Set(pool.map(\.ratingKey))
        slots = slots.filter { keys.contains($0.value.ratingKey) }
        let cutoff = Int(Date.now.timeIntervalSince1970 - Self.recentlyPlayed)
        let open = pool.filter { ($0.lastViewedAt ?? 0) < cutoff }
        // On Rotation's order, the root's default sort: recent plays
        // weigh more, per track. Its head is the most played; its foot,
        // then what no play this past year scores at all (longest ago
        // first), is the least.
        let rotation = catalog.rotation
        let scored = { (album: PlexAlbum) in
            rotation.isEmpty ? (album.viewCount ?? 0) > 0 : rotation.albums[album.ratingKey] != nil
        }
        for slot in Slot.fillOrder where slots[slot] == nil {
            let taken = Set(slots.values.map(\.ratingKey))
            let free = open.filter { !taken.contains($0.ratingKey) }
            let played = free.filter { $0.lastViewedAt != nil }
            let ranked = AlbumView.mostPlayed.sorted(played.filter(scored), rotation: rotation)
            // One of the tenth at either end, so a row isn't the same
            // album every launch.
            let pick: PlexAlbum? = switch slot {
            case .favorite:
                Self.top(ranked).randomElement()
            case .random:
                free.randomElement()
            case .forgotten:
                Self.top(
                    played.filter { !scored($0) }.sorted { ($0.lastViewedAt ?? 0) < ($1.lastViewedAt ?? 0) }
                        + ranked.reversed()
                ).randomElement()
            }
            if let pick { slots[slot] = pick }
        }
    }

    /// The first tenth of `albums`, in their order, never fewer than five
    /// (or all of them, when there are fewer): a pool that grows with
    /// the library, so a big one still varies and a small one still has
    /// something to offer.
    private static func top(_ albums: [PlexAlbum]) -> ArraySlice<PlexAlbum> {
        albums.prefix(max(albums.count / 10, 5))
    }

    // MARK: - Playing

    /// The album start to finish, as its page's Play would: the tracks a
    /// listening rider vetoed inside it skipped, offline only what has a
    /// file. Recorded as a recent mix like any whole album played.
    private func start(_ album: PlexAlbum) async {
        guard let library = model.library else { return }
        starting = album.ratingKey
        defer { starting = nil }
        let hidden = model.roster.hidden
        guard let tracks = try? await library.tracks(inAlbum: album.ratingKey) else {
            navigator.notice = "Couldn’t load \(album.title)."
            return
        }
        let playable = tracks.filter { !hidden.hides($0, within: .album) && model.downloads.canPlay($0) }
        guard !playable.isEmpty else {
            navigator.notice = "Nothing on \(album.title) can play right now."
            return
        }
        player.play(playable, startingAt: 0, library: library)
        model.recordMix([MixPick(album: album)], style: .play, player: player)
        slots = slots.filter { $0.value.ratingKey != album.ratingKey }
    }
}

/// Now Playing as a sheet or cover: the idle view while last session's
/// queue waits to be resumed, the player once it plays. The swap happens
/// in place, so Resume or an album turns the sheet into the player.
struct PresentedNowPlaying: View {
    let model: AppModel
    let catalog: LibraryCatalog
    let style: NowPlayingStyle
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var presentation
    @Environment(LibraryNavigator.self) private var navigator
    @State private var routePicker = RoutePickerHandle()

    var body: some View {
        Group {
            if player.isRestored {
                idle.transition(.opacity)
            } else {
                NowPlayingView(model: model, style: style).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: player.isRestored)
    }

    @ViewBuilder private var idle: some View {
        if style == .fullScreen {
            // The cover's chrome, as the player's: a close button, and
            // giving way to the column when the window turns wide.
            NavigationStack {
                NowPlayingIdleView(model: model, catalog: catalog)
                    .navigationTitle("Now Playing")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Hide Now Playing", systemImage: "xmark") { presentation.isShown = false }
                        }
                    }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if NowPlayingPresentation.wantsColumn(size) { presentation.isShown = false }
            }
        } else if navigator.hasVerticalBar {
            // Under a vertical strip, AirPlay as a strip item, from a
            // stack of its own as the player's sheet has: without it the
            // strip stood empty and there was no AirPlay at all. Nothing
            // plays yet, so the heart, repeat and shuffle wait for the
            // player.
            NavigationStack {
                NowPlayingIdleView(model: model, catalog: catalog)
                    .hostsRoutePicker(routePicker, when: true)
                    .toolbar { StripAirPlayItem(picker: routePicker, shown: true, leading: false) }
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            NowPlayingIdleView(model: model, catalog: catalog)
        }
    }
}
