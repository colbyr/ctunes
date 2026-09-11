import PlexKit
import SwiftUI

struct TracksView: View {
    let model: AppModel
    let album: PlexAlbum
    /// The stack's path, for pushing the artist page by hand: a
    /// NavigationLink in the header row would make the whole row a link.
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player

    @State private var tracks: [PlexTrack] = []
    @State private var loaded = false
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @State private var scrollPosition = ScrollPosition()
    @Environment(NowPlayingPresentation.self) private var nowPlaying

    private var offline: Bool { model.library?.isOffline ?? false }

    /// Debug hooks so playback can be started and inspected in a simulator,
    /// where there is no way to tap a row.
    private static var autoPlay: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] != nil
        #else
        false
        #endif
    }
    /// `last` starts on the final track a few seconds from its end, so the
    /// queue runs out almost immediately.
    private static var autoPlayLast: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] == "last"
        #else
        false
        #endif
    }
    /// `end` starts on the first track a few seconds from its end, so the
    /// transition to the next track happens almost immediately.
    private static var autoPlayNearEnd: Bool {
        #if DEBUG
        autoPlayLast || ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] == "end"
        #else
        false
        #endif
    }
    /// `skip` starts on the first track and skips to the next 8s in.
    private static var autoSkip: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] == "skip"
        #else
        false
        #endif
    }
    private static var autoShowNowPlaying: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_NOWPLAYING"] == "1"
        #else
        false
        #endif
    }
    /// Appends the album to the queue a second time, so Up Next is populated
    /// with duplicate tracks — the case the queue's entry ids exist for.
    private static var autoEnqueue: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_ENQUEUE"] == "1"
        #else
        false
        #endif
    }
    /// Pins the album once its tracks load, so the download ring and the
    /// files under Application Support can be checked in a simulator.
    private static var autoPin: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_PIN"] == "1"
        #else
        false
        #endif
    }

    /// Tracks grouped by disc, in playback order. `offset` indexes the flat
    /// `tracks` array so a tap can start the whole album from that row.
    private var discs: [(number: Int?, rows: [(offset: Int, track: PlexTrack)])] {
        var result: [(number: Int?, rows: [(offset: Int, track: PlexTrack)])] = []
        for (offset, track) in tracks.enumerated() {
            if let last = result.indices.last, result[last].number == track.parentIndex {
                result[last].rows.append((offset, track))
            } else {
                result.append((track.parentIndex, [(offset, track)]))
            }
        }
        return result
    }

    var body: some View {
        let discs = discs
        // A ScrollView, not a List: in a List a context menu on any part
        // of a row is the row's, so a long press on the cover lit up the
        // whole header, controls and all. Favorites keeps its List for the
        // swipe.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.init(top: 8, leading: Self.margin, bottom: 4, trailing: Self.margin))
                ForEach(Array(discs.enumerated()), id: \.offset) { _, disc in
                    if discs.count > 1, let number = disc.number {
                        Text(verbatim: "Disc \(number)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.init(top: 20, leading: Self.margin, bottom: 4, trailing: Self.margin))
                    }
                    ForEach(disc.rows, id: \.track.id) { offset, track in
                        row(track, at: offset)
                        Divider().padding(.leading, Self.margin + 36)
                    }
                }
            }
        }
        .artworkBackground(artworkURL)
        .scrollPosition($scrollPosition)
        // Past the cover, the avatars and the cards.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 320
        } action: { _, scrolledPast in
            withAnimation(.snappy) { actionsVisible = !scrolledPast }
        }
        .overlay {
            if !loaded { ProgressView() }
        }
        .navigationTitle(album.title)
        // Same edge as the browse root; see MusicView for why not `.hard`.
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 84, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title bar carries the artist under the title, and opens
            // their page: the native subtitle is plain text, so this is a
            // principal item drawn to match it, without the glass.
            if let artist = album.parentTitle {
                ToolbarItem(placement: .principal) {
                    titleBlock(artist: artist)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AlbumMenu(model: model, album: album, tracks: tracks, showAlbum: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            // The cards' actions follow you down the list as icons.
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Play", systemImage: "play.fill", action: play)
                        .disabled(playableTracks.isEmpty)
                    Button("Shuffle", systemImage: "shuffle", action: shuffle)
                        .disabled(playableTracks.isEmpty)
                }
            }
        }
        // Keyed on the generation so going offline, or coming back, reloads
        // from whichever library is current.
        .task(id: model.libraryGeneration) {
            await load()
            guard let library = model.library else { return }
            if Self.autoPlay, !tracks.isEmpty {
                let start = Self.autoPlayLast ? tracks.count - 1 : 0
                player.play(tracks, startingAt: start, library: library)
                if Self.autoPlayNearEnd, let seconds = tracks[start].durationSeconds {
                    // Let the item become ready before seeking near its end.
                    try? await Task.sleep(for: .seconds(2))
                    player.seek(to: max(0, seconds - 4))
                }
                if Self.autoSkip {
                    // A skip mid-track, while the server is still serving
                    // the first one: the transition the end hook can't reach.
                    try? await Task.sleep(for: .seconds(8))
                    player.next()
                }
                if Self.autoShowNowPlaying { nowPlaying.isShown = true }
            }
            if Self.autoEnqueue, !tracks.isEmpty {
                player.addToQueue(tracks, library: library)
            }
            #if DEBUG
            if let y = ProcessInfo.processInfo.environment["CTUNES_DEV_SCROLL"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                scrollPosition.scrollTo(y: y)
            }
            #endif
        }
        .refreshable { await load() }
    }

    private static let margin: CGFloat = 16

    private func load() async {
        guard let library = model.library else { return }
        do {
            tracks = try await library.tracks(inAlbum: album.ratingKey)
        } catch {
            await model.connectionLost(error)
            if model.library?.isOffline != true { tracks = [] }
            return
        }
        loaded = true
        await model.rememberTracks(tracks, inAlbum: album)
        if Self.autoPin, !library.isOffline, !tracks.isEmpty, !model.downloads.isPinned(album) {
            model.downloads.pin(album, tracks: tracks, section: model.selectedSection?.key ?? "", library: library)
        }
        // The header already fetches the album cover at 600; warm the
        // same size for any track that carries its own art so Now
        // Playing and the lock screen open without a network round trip.
        for thumb in Set(tracks.compactMap(\.thumb)) where thumb != album.thumb {
            ImageLoader.shared.prewarm(library.artworkURL(thumb, size: 600))
        }
    }

    /// Fall back to the tracks' art: a track's thumb is its album's, so
    /// this covers an album record with no thumb of its own (which is
    /// also what the CTUNES_DEV_ALBUM hook produces).
    private var artworkURL: URL? {
        model.library?.artworkURL(album.thumb ?? tracks.first?.thumb, size: 600)
    }


    /// Title over the artist, the artist tappable. Sized like the bar's own
    /// title and subtitle so it reads as the native pair.
    private func titleBlock(artist: String) -> some View {
        Button {
            if let key = album.parentRatingKey {
                path.append(ArtistRoute(ratingKey: key, title: artist))
            }
        } label: {
            VStack(spacing: 1) {
                Text(album.title)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(artist).font(.caption)
                    if album.parentRatingKey != nil {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(album.parentRatingKey == nil)
        .accessibilityLabel("\(album.title), open \(artist)")
    }

    private var header: some View {
        let downloaded = model.downloads.isDownloaded(album)
        let downloading = !downloaded && model.downloads.isPinned(album)
        return VStack(spacing: 12) {
            // The cover carries the download mark the grid tiles do; the
            // download itself lives in the menu, a long press away.
            Artwork(url: artworkURL, size: 240, corner: 12)
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) {
                    if downloaded || downloading { DownloadedBadge(downloading: downloading, large: true) }
                }
                .contextMenu { AlbumMenu(model: model, album: album, tracks: tracks, showAlbum: false) }
                .padding(.bottom, 8)
            if let artistKey = album.parentRatingKey {
                ListenerVetoes(model: model, artistKey: artistKey)
                HiddenRightNowLabel(model: model, artistKey: artistKey)
            }
            HStack(spacing: 12) {
                MixActionCard(systemImage: "play.fill", title: "Play", subtitle: nil,
                              enabled: !playableTracks.isEmpty, loading: false, tint: .accentText, action: play)
                MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                              enabled: !playableTracks.isEmpty, loading: false, tint: .accentText, action: shuffle)
            }
            .padding(.top, 8)
            if case .partial(let count)? = model.downloads.status(album) {
                Text("\(count) track\(count == 1 ? "" : "s") can't be downloaded")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ track: PlexTrack, at index: Int) -> some View {
        let favorite = model.isFavorite(track)
        let downloaded = model.downloads.isPinned(track)
        // Offline, a row with no file has nothing to play; a file left in
        // the cache root from an earlier play counts.
        let playable = !offline || model.downloads.isAvailable(track)
        // The ··· sits beside the tappable part rather than inside it, so
        // its tap is never also a tap on the row. The menu it opens is the
        // long press's, minus Go to Album: this is the album.
        return HStack(spacing: 4) {
            Button {
                guard let library = model.library, playable else { return }
                player.play(tracks, startingAt: index, library: library)
                nowPlaying.isShown = true
            } label: {
                HStack(spacing: 12) {
                    Text(track.index.map(String.init) ?? "–")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                        if let artist = track.trackArtist {
                            Text(artist)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // Both marks keep their slot when off, so the duration column
                    // doesn't shift as hearts and files come and go.
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(downloaded ? 1 : 0)
                        .accessibilityHidden(!downloaded)
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(Color.heart)
                        .opacity(favorite ? 1 : 0)
                        .accessibilityHidden(!favorite)
                    if let seconds = track.durationSeconds {
                        Text(Self.duration(seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(playable ? 1 : 0.35)
            .foregroundStyle(player.currentTrack?.id == track.id ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.primary))
            MoreButton { TrackMenu(model: model, track: track, placement: .list(siblings: tracks), showAlbum: false) }
        }
        .padding(.init(top: 8, leading: Self.margin, bottom: 8, trailing: Self.margin - 4))
        .contextMenu { TrackMenu(model: model, track: track, placement: .list(siblings: tracks), showAlbum: false) }
    }


    private var playableTracks: [PlexTrack] {
        offline ? tracks.filter { model.downloads.isAvailable($0) } : tracks
    }

    private func play() {
        guard let library = model.library, !playableTracks.isEmpty else { return }
        player.play(playableTracks, startingAt: 0, library: library)
        nowPlaying.isShown = true
    }

    /// Spread-shuffled once at enqueue time, the same way Shuffle Favorites does it.
    private func shuffle() {
        guard let library = model.library, !playableTracks.isEmpty else { return }
        player.play(playableTracks.spreadShuffled(), startingAt: 0, library: library)
        nowPlaying.isShown = true
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One avatar per listener beside the artist name, the owner included.
/// Tapping strikes the listener out: "not for Laura". A veto is per
/// artist, not per album. Shared by the album and artist pages.
struct ListenerVetoes: View {
    let model: AppModel
    let artistKey: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.roster.listeners) { listener in
                let vetoed = listener.vetoedArtistKeys.contains(artistKey)
                Button {
                    withAnimation(.snappy) { model.toggleVeto(artistKey: artistKey, for: listener.id) }
                } label: {
                    ListenerAvatar(listener: listener, size: 28, struck: vetoed)
                        .opacity(vetoed ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vetoed ? "Not for \(listener.name), tap to allow" : "\(listener.name) listens, tap to hide")
            }
        }
    }
}

/// "Hidden right now — Laura is listening" under the vetoes, only while a
/// listening rider has the artist vetoed. Nothing otherwise, so the header
/// doesn't reserve a line for it.
struct HiddenRightNowLabel: View {
    let model: AppModel
    let artistKey: String

    var body: some View {
        let listening = model.roster.active.filter { $0.vetoedArtistKeys.contains(artistKey) }
        if !listening.isEmpty {
            let names = listening.map { $0.isOwner ? "you" : $0.name }
            let verb = listening.count == 1 && !listening[0].isOwner ? "is" : "are"
            Label(
                "Hidden right now — \(ListenerRoster.joinNames(names)) \(verb) listening",
                systemImage: "eye.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .capsule)
            .transition(.opacity)
        }
    }
}

/// The album's download state as one circular button: an arrow to pin, a
/// ring filling as tracks land, a check when every file is down. Tapping a
/// pinned album asks before removing it.
