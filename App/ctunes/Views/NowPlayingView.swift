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
        let ended = player.hasEnded

        List {
            // The header scrolls with the queue, Spotify-style, so Up Next
            // gets the whole sheet rather than whatever is left under the art.
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            // No header once the queue has ended: there is nothing next.
            Section {
                if ended {
                    endOfQueue
                } else if upcoming.isEmpty {
                    Text("Last track").foregroundStyle(.secondary)
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
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.row)
                    // Zero insets so the press highlight reaches the row edges;
                    // the label pads itself back to the standard inset.
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { player.remove(entry) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } header: {
                if !ended { Text("Up Next") }
            }
        }
        .listStyle(.plain)
    }

    private var endOfQueue: some View {
        VStack(spacing: 12) {
            Text("That's everything")
                .font(.headline)
            Text("The queue has finished playing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowSeparator(.hidden)
    }

    private var header: some View {
        VStack(spacing: 24) {
            // Edge to edge less a margin, so the art is as big as the sheet
            // allows rather than a fixed 300pt. Inset from the top by the same
            // 28pt it is from the sides (16 header + 12 here).
            Artwork(url: model.library?.artworkURL(player.currentTrack?.thumb, size: 900),
                    size: nil, corner: 14)
                .shadow(radius: 12, y: 6)
                .padding(.horizontal, 12)
                .padding(.top, 28)

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

            transport
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
        // Overlaid rather than in the stack so it takes no vertical space.
        .overlay(alignment: .top) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 40, height: 5)
                .padding(.top, 8)
        }
    }

    /// Once the queue has ended the only sensible action is to start over,
    /// so the play button becomes a restart and the rest dims.
    private var transport: some View {
        let ended = player.hasEnded
        let dimmed = ended ? 0.35 : 1.0
        return HStack {
            modeButton(
                systemImage: "shuffle",
                active: player.isShuffled,
                label: player.isShuffled ? "Shuffle on" : "Shuffle off"
            ) { player.toggleShuffle() }
            .opacity(dimmed)
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .opacity(dimmed)
            Spacer()
            if ended {
                Button { player.restart() } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 64))
                }
                .foregroundStyle(.tint)
                .accessibilityLabel("Play again")
            } else {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .opacity(dimmed)
            Spacer()
            modeButton(
                systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                active: player.repeatMode != .off,
                label: repeatLabel
            ) { player.cycleRepeat() }
            .opacity(dimmed)
        }
        .animation(.default, value: ended)
        .padding(.horizontal, 8)
        // Plain so a tap on a control isn't swallowed as a row tap.
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    /// Shuffle and repeat: tinted while on, dimmed while off, with a
    /// generous hit area since the glyphs are small.
    private func modeButton(
        systemImage: String, active: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
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

/// A list row that highlights while pressed, the way a plain table cell does.
/// SwiftUI's `.plain` style hit-tests only the label's opaque content and
/// gives no feedback, so a tap in the row's empty space went nowhere.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(configuration.isPressed ? Color(.systemGray4) : .clear)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}
