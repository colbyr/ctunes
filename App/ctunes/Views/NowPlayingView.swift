import PlexKit
import SwiftUI

struct NowPlayingView: View {
    let model: AppModel
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Held while dragging so the slider doesn't fight the time observer.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Artwork(url: model.library?.artworkURL(player.currentTrack?.thumb, size: 900),
                    size: 300, corner: 12)
                .shadow(radius: 12, y: 6)
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text(player.currentTrack?.title ?? "Nothing playing")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(player.currentTrack?.grandparentTitle ?? "")
                    .foregroundStyle(.secondary)
                Text(player.currentTrack?.parentTitle ?? "")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)

            scrubber

            HStack(spacing: 48) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
            }
            .foregroundStyle(.primary)

            Spacer()
        }
        .padding()
    }

    private var scrubber: some View {
        // Read unconditionally rather than behind `scrubbing ?? …`. Observation
        // registers only the properties actually touched while the body runs,
        // so a short-circuited read drops the dependency on currentTime and the
        // clock stops updating until the view is rebuilt.
        let elapsed = player.currentTime
        let total = max(player.duration, 1)
        let shown = min(scrubbing ?? elapsed, total)

        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { shown },
                    set: { scrubbing = $0 }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    if editing {
                        // Pin the starting point so the thumb doesn't fight the
                        // time observer mid-drag.
                        scrubbing = scrubbing ?? elapsed
                    } else {
                        if let target = scrubbing { player.seek(to: target) }
                        scrubbing = nil
                    }
                }
            )
            HStack {
                Text(TracksView.duration(shown))
                Spacer()
                Text(TracksView.duration(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        // A track change mid-scrub would otherwise leave the thumb stuck.
        .onChange(of: player.currentTrack?.id) { scrubbing = nil }
    }
}

/// Persistent bar above the tab/nav content, tapped to open the full screen.
struct MiniPlayer: View {
    let model: AppModel
    @Environment(AudioPlayer.self) private var player
    @State private var showingNowPlaying = false

    var body: some View {
        if let track = player.currentTrack {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    Artwork(url: model.library?.artworkURL(track.thumb), size: 40, corner: 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.footnote.weight(.medium)).lineLimit(1)
                        Text(track.grandparentTitle ?? "")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.body)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingView(model: model)
            }
        }
    }
}
