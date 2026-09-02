import PlexKit
import SwiftUI

struct NowPlayingView: View {
    let model: AppModel
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Held while dragging so the slider doesn't fight the time observer.
    @State private var scrubbing: Double?

    var body: some View {
        // Read unconditionally so the list observes queue mutations.
        let upcoming = player.upcoming

        List {
            // The header scrolls with the queue, Spotify-style, so Up Next
            // gets the whole sheet rather than whatever is left under the art.
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            Section("Up Next") {
                if upcoming.isEmpty {
                    Text("End of queue").foregroundStyle(.secondary)
                }
                ForEach(upcoming) { entry in
                    Button { player.jump(to: entry) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title).lineLimit(1)
                                Text(entry.item.grandparentTitle ?? "")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let seconds = entry.item.durationSeconds {
                                Text(TracksView.duration(seconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { player.remove(entry) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var header: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Artwork(url: model.library?.artworkURL(player.currentTrack?.thumb, size: 600),
                    size: 300, corner: 12)
                .shadow(radius: 12, y: 6)
                .padding(.top, 12)

            HStack(alignment: .top) {
                // Balances the heart so the text stays centred.
                Color.clear.frame(width: 44, height: 1)
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
                .frame(maxWidth: .infinity)
                HeartButton(model: model, track: player.currentTrack)
                    .frame(width: 44)
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
            // Plain so a tap on a control isn't swallowed as a row tap.
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
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
        // Keyed on the queue entry, not the track: two adjacent copies of the
        // same track share a ratingKey and would otherwise not reset it.
        .onChange(of: player.queue.currentEntry?.id) { scrubbing = nil }
    }
}

/// Heart toggle for one track. Disabled when there's no track to rate.
struct HeartButton: View {
    let model: AppModel
    let track: PlexTrack?

    var body: some View {
        // Read unconditionally so observation tracks the override map.
        let favorite = track.map { model.isFavorite($0) } ?? false
        Button {
            guard let track else { return }
            Task { await model.toggleFavorite(track) }
        } label: {
            Image(systemName: favorite ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(favorite ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(track == nil)
        .accessibilityLabel(favorite ? "Unfavorite" : "Favorite")
    }
}
