import PlexKit
import SwiftUI

/// Whether Now Playing is on screen. One flag shared by every screen that
/// can open it, so the host lives in one place (`LibraryView`): a cover in
/// a narrow window, a trailing column beside the stack in a wide one.
@MainActor @Observable
final class NowPlayingPresentation {
    var isShown = false
    /// Set by the host from the window width, not the size class: a Mac
    /// window only turns compact a hair above its minimum width, and the
    /// column has to give way to the cover well before the window is
    /// that narrow.
    var isColumn = false
}

/// How Now Playing is on screen. The column and the cover pin the header
/// and scroll only the queue; the phone scrolls the header away with it.
enum NowPlayingStyle {
    /// A phone: covers the whole screen, the header scrolling with the
    /// queue. A chevron closes it, as does pulling the top down.
    case phone
    /// Regular width but too narrow for the column: covers the stack, with
    /// a close button in its toolbar.
    case fullScreen
    /// Beside the stack in a wide window. Always there; nothing closes it.
    case column
}

struct NowPlayingView: View {
    let model: AppModel
    var style: NowPlayingStyle = .phone
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var presentation
    @Environment(LibraryNavigator.self) private var navigator

    /// Held while dragging so the slider doesn't fight the time observer.
    @State private var scrubbing: Double?

    /// The art on show, at the size the header draws it; the background
    /// takes its color from the same file so it is never a second fetch.
    private var artworkURL: URL? {
        model.library?.artworkURL(player.currentTrack?.thumb, size: 900)
    }

    var body: some View {
        if style == .phone {
            List {
                // The header scrolls with the queue, Spotify-style, so Up Next
                // gets the whole screen rather than whatever is left under the art.
                Section {
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                queueSection
            }
            .listStyle(.plain)
            .artworkBackground(artworkURL)
            // A full-screen cover has no drag to dismiss of its own, so
            // pulling the top well past its rest position stands in for it.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < -70
            } action: { _, pulled in
                if pulled { presentation.isShown = false }
            }
        } else {
            // The header lives outside the List on purpose. A List row whose
            // height follows the width (the art is a square of the column)
            // recurses in UICollectionView's layout during a live window
            // resize on the Mac; a plain VStack does not. The queue rows are
            // fixed height, so they stay in a List and keep swipe to remove.
            // Its own stack so the title bar lines up with the one in the
            // stack beside it, and the cover's close button is a real
            // toolbar item.
            NavigationStack {
                VStack(spacing: 0) {
                    header
                    List { queueSection }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                }
                .artworkBackground(artworkURL)
                .navigationTitle("Now Playing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if style == .fullScreen {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Hide Now Playing", systemImage: "xmark") { presentation.isShown = false }
                        }
                    }
                }
            }
        }
    }

    /// Up Next. No header once the queue has ended: there is nothing next.
    private var queueSection: some View {
        // Read unconditionally so the list observes queue mutations.
        let upcoming = player.upcoming
        let ended = player.hasEnded

        return Section {
            if ended {
                endOfQueue
            } else if upcoming.isEmpty {
                Text("Last track").foregroundStyle(.secondary)
            }
            ForEach(upcoming) { entry in
                HStack(spacing: 0) {
                    Button { player.jump(to: entry) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: model.library?.artworkURL(entry.item.thumb), size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title).lineLimit(1)
                                Text([entry.item.trackArtist, entry.item.grandparentTitle].compactMap { $0 }.joined(separator: " · "))
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
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.row)
                    MoreButton { TrackMenu(model: model, track: entry.item, placement: .queued(entry)) }
                        .padding(.trailing, 12)
                }
                // Zero insets so the press highlight reaches the row edges;
                // the label pads itself back to the standard inset.
                .listRowInsets(EdgeInsets())
                .contextMenu { TrackMenu(model: model, track: entry.item, placement: .queued(entry)) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { player.remove(entry) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } header: {
            if !ended { upNextHeader }
        }
        .listRowBackground(Color.clear)
    }

    /// The title with repeat and shuffle at its trailing edge: both act on
    /// the queue, so they live with it rather than in the transport.
    private var upNextHeader: some View {
        HStack(spacing: 4) {
            Text("Up Next")
            Spacer()
            modeButton(
                systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                active: player.repeatMode != .off,
                label: repeatLabel
            ) { player.cycleRepeat() }
            modeButton(
                systemImage: "shuffle",
                active: player.isShuffled,
                label: player.isShuffled ? "Shuffle on" : "Shuffle off"
            ) { player.toggleShuffle() }
        }
        .buttonStyle(.plain)
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

    private var albumLine: String {
        guard let track = player.currentTrack else { return "" }
        let artist = track.trackArtist == nil ? nil : track.grandparentTitle
        return [track.parentTitle, artist].compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        VStack(spacing: 24) {
            // The phone has no title bar, so a grab bar sits centered at
            // the top, the way a sheet's handle does; tapping it closes too.
            if style == .phone {
                Button { presentation.isShown = false } label: {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Now Playing")
            }
            // Edge to edge less a margin, so the art is as big as the screen
            // allows rather than a fixed 300pt. In the column the toolbar
            // already clears the top, and the art is capped so a wide column
            // in a short window still leaves room for the queue.
            Artwork(url: artworkURL, size: nil, corner: 14)
                .shadow(radius: 12, y: 6)
                .frame(maxWidth: style == .phone ? nil : 400)
                .padding(.horizontal, 12)
                .padding(.top, style == .phone ? 0 : 8)
                // A long press on the art is the track's menu: the way to
                // its album, and to who hears its artist.
                .contextMenu {
                    if let track = player.currentTrack {
                        TrackMenu(model: model, track: track, placement: .playing)
                    }
                }

            HStack(alignment: .top) {
                // Balances the heart so the text stays centred.
                Color.clear.frame(width: 44, height: 1)
                VStack(spacing: 6) {
                    Text(player.currentTrack?.title ?? "Nothing playing")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    // The credited artist takes the artist line on a
                    // compilation or a feature; the album artist moves down
                    // beside the album so both still show. Tapping opens the
                    // album artist's page, the one with a rating key.
                    artistLine
                    Text(albumLine)
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
    }

    @ViewBuilder private var artistLine: some View {
        let track = player.currentTrack
        let name = track?.trackArtist ?? track?.grandparentTitle ?? ""
        if let track, let key = track.grandparentRatingKey, let artist = track.grandparentTitle {
            Button {
                // The cover gets out of the way; the column stays put.
                if !presentation.isColumn { presentation.isShown = false }
                navigator.open(.artist(ArtistRoute(ratingKey: key, title: artist)))
            } label: {
                HStack(spacing: 4) {
                    Text(name)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(artist)")
        } else {
            Text(name).foregroundStyle(.secondary)
        }
    }

    /// Once the queue has ended the only sensible action is to start over,
    /// so the play button becomes a restart and the rest dims.
    private var transport: some View {
        let ended = player.hasEnded
        let dimmed = ended ? 0.35 : 1.0
        return HStack(spacing: 40) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .opacity(dimmed)
            if ended {
                Button { player.restart() } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 64))
                }
                .foregroundStyle(Color.bigButton)
                .accessibilityLabel("Play again")
            } else {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .contentTransition(.symbolEffect(.replace))
                }
                // Ink disc by day, amber by night; the glyph is the cutout.
                .foregroundStyle(Color.bigButton)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
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

    /// Repeat and shuffle: tinted while on, dimmed while off, with a
    /// generous hit area since the glyphs are small.
    private func modeButton(
        systemImage: String, active: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.secondary))
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
            .tint(Color.amber)
            HStack {
                Text(TracksView.duration(shown))
                Spacer()
                Text(TracksView.duration(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .onAppear { player.scrubberAppeared() }
        .onDisappear { player.scrubberDisappeared() }
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
                .foregroundStyle(favorite ? AnyShapeStyle(Color.heart) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        // Hearts are read-only offline.
        .disabled(track == nil || model.library?.isOffline == true)
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
            .background(configuration.isPressed ? Color.divider : .clear)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}
