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
        ProcessInfo.processInfo.environment["CTUNES_DEV_AUTOPLAY"] == "1"
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

    var body: some View {
        List {
            Section {
                Button(action: shuffle) {
                    HStack {
                        Label("Shuffle", systemImage: "shuffle")
                        Spacer()
                    }
                }
                .disabled(tracks.isEmpty)
            } header: {
                VStack(spacing: 8) {
                    Artwork(url: model.library?.artworkURL(album.thumb, size: 600),
                            size: 180, corner: 10)
                    Text(album.title).font(.headline)
                    if let artist = album.parentTitle {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textCase(nil)
            }

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    let favorite = model.isFavorite(track)
                    Button {
                        guard let library = model.library else { return }
                        player.play(tracks, startingAt: index, library: library)
                        showingNowPlaying = true
                    } label: {
                    HStack(spacing: 12) {
                        Text(track.index.map(String.init) ?? "–")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(track.title)
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
            }
        }
        .overlay {
            if !loaded { ProgressView() }
        }
        .navigationTitle(album.title)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { enqueue(tracks, next: true) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { enqueue(tracks, next: false) } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(tracks.isEmpty)
        }
        .task {
            guard let library = model.library else { return }
            tracks = (try? await library.tracks(inAlbum: album.ratingKey)) ?? []
            loaded = true
            if Self.autoPlay, !tracks.isEmpty {
                player.play(tracks, startingAt: 0, library: library)
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
