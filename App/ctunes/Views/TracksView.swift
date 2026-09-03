import PlexKit
import SwiftUI

struct TracksView: View {
    let model: AppModel
    let album: PlexAlbum
    @Environment(AudioPlayer.self) private var player

    @State private var tracks: [PlexTrack] = []
    @State private var loaded = false
    @State private var showingNowPlaying = false

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
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            }

            ForEach(Array(discs.enumerated()), id: \.offset) { _, disc in
                Section {
                    ForEach(disc.rows, id: \.track.id) { offset, track in
                        row(track, at: offset)
                    }
                } header: {
                    if discs.count > 1, let number = disc.number {
                        Text(verbatim: "Disc \(number)")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !loaded { ProgressView() }
        }
        .navigationTitle(album.title)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let library = model.library else { return }
            tracks = (try? await library.tracks(inAlbum: album.ratingKey)) ?? []
            loaded = true
            // The header already fetches the album cover at 600; warm the
            // same size for any track that carries its own art so Now
            // Playing and the lock screen open without a network round trip.
            for thumb in Set(tracks.compactMap(\.thumb)) where thumb != album.thumb {
                ImageLoader.shared.prewarm(library.artworkURL(thumb, size: 600))
            }
            if Self.autoPlay, !tracks.isEmpty {
                let start = Self.autoPlayLast ? tracks.count - 1 : 0
                player.play(tracks, startingAt: start, library: library)
                if Self.autoPlayNearEnd, let seconds = tracks[start].durationSeconds {
                    // Let the item become ready before seeking near its end.
                    try? await Task.sleep(for: .seconds(2))
                    player.seek(to: max(0, seconds - 4))
                }
                showingNowPlaying = Self.autoShowNowPlaying
            }
            if Self.autoEnqueue, !tracks.isEmpty {
                player.addToQueue(tracks, library: library)
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(model: model)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // Fall back to the tracks' art: a track's thumb is its album's, so
            // this covers an album record with no thumb of its own (which is
            // also what the CTUNES_DEV_ALBUM hook produces).
            Artwork(url: model.library?.artworkURL(album.thumb ?? tracks.first?.thumb, size: 600),
                    size: 180, corner: 10)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
            Text(album.title).font(.headline)
            HStack(spacing: 10) {
                if let artist = album.parentTitle {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary)
                }
                if let artistKey = album.parentRatingKey, !model.roster.listeners.isEmpty {
                    Divider().frame(height: 16)
                    ListenerVetoes(model: model, artistKey: artistKey)
                }
            }
            if let artistKey = album.parentRatingKey {
                let listening = model.roster.active.filter { $0.vetoedArtistKeys.contains(artistKey) }
                if !listening.isEmpty {
                    Label(
                        "Hidden right now — \(ListenerRoster.joinNames(listening.map(\.name))) \(listening.count == 1 ? "is" : "are") listening",
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
            actions
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// Play, shuffle and the two queue actions as a centered row of icon
    /// buttons, so nothing hides behind a menu.
    private var actions: some View {
        HStack(spacing: 12) {
            Button { enqueue(tracks, next: true) } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .accessibilityLabel("Play Next")
            Button { enqueue(tracks, next: false) } label: {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
            }
            .accessibilityLabel("Add to Queue")
            Button(action: shuffle) {
                Image(systemName: "shuffle")
            }
            .accessibilityLabel("Shuffle")
            Button(action: play) {
                Image(systemName: "play.fill")
            }
            .accessibilityLabel("Play")
            .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }

    private func row(_ track: PlexTrack, at index: Int) -> some View {
        let favorite = model.isFavorite(track)
        return Button {
            guard let library = model.library else { return }
            player.play(tracks, startingAt: index, library: library)
            showingNowPlaying = true
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
                if favorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
                if let seconds = track.durationSeconds {
                    Text(Self.duration(seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(player.currentTrack?.id == track.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { enqueue([track], next: true) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.orange)
            Button { enqueue([track], next: false) } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await model.toggleFavorite(track) }
            } label: {
                Label(favorite ? "Unfavorite" : "Favorite",
                      systemImage: favorite ? "heart.slash" : "heart.fill")
            }
            .tint(.pink)
        }
    }

    private func play() {
        guard let library = model.library, !tracks.isEmpty else { return }
        player.play(tracks, startingAt: 0, library: library)
        showingNowPlaying = true
    }

    /// Shuffled once at enqueue time, the same way Shuffle Favorites does it.
    private func shuffle() {
        guard let library = model.library, !tracks.isEmpty else { return }
        player.play(tracks.shuffled(), startingAt: 0, library: library)
        showingNowPlaying = true
    }

    private func enqueue(_ tracks: [PlexTrack], next: Bool) {
        guard let library = model.library else { return }
        next ? player.playNext(tracks, library: library)
             : player.addToQueue(tracks, library: library)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One avatar per listener beside the artist name. Tapping strikes the
/// listener out: "not for Laura". A veto is per artist, not per album.
private struct ListenerVetoes: View {
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
