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

    /// Narrower than this and Now Playing is a presentation: the phone
    /// layout. An iPad is a column in landscape and a cover in portrait,
    /// where a column would leave two tiles across.
    static let columnThreshold: CGFloat = 960
    /// A window wider than it is tall takes the column from here. An
    /// iPhone Duo open in landscape is 951pt less the vertical bar's
    /// inset, about 850 usable, where two pages of 425 fit the browser's
    /// tiles two across; an 11" iPad's 834pt portrait is taller than wide
    /// and keeps the cover.
    static let wideColumnThreshold: CGFloat = 800

    /// Whether a window of this size shows the column. The host decides
    /// from its own size, and the cover from its own, since a full-screen
    /// presentation takes the host's view out of the window.
    static func wantsColumn(_ size: CGSize) -> Bool {
        size.width >= columnThreshold
            || (size.width > size.height && size.width >= wideColumnThreshold)
    }
}

/// How Now Playing is on screen. The cover pins the header and scrolls
/// only the queue; the phone and the column scroll the header away with
/// it.
enum NowPlayingStyle {
    /// A phone: a sheet, the header scrolling with the queue. Dragging it
    /// down closes it, as any sheet does.
    case phone
    /// Regular width but too narrow for the column: covers the stack, with
    /// a close button in its toolbar.
    case fullScreen
    /// Beside the stack in a wide window. Always there; nothing closes it.
    /// The phone's layout under a title, half the screen wide: the
    /// cover's split header beside the browser read as another screen.
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
    /// Which way the arrangement split its panes, from the environment
    /// inside the art pane; nil before it reports, and on iOS 27.0.
    @State private var paneAxis: Axis?
    /// The column's size, for the art's edge: a square that follows the
    /// row's width recurses in a List during a live resize on the Mac, so
    /// the column's art is sized from a measurement instead.
    @State private var columnSize: CGSize = .zero

    /// Edge to edge of the column, as on the phone, less the header's and
    /// the art block's margins, but no taller than 40% of the column: a
    /// Duo open in landscape is 669pt tall, and art the full 419pt width
    /// left nothing of the transport on screen; half the height still
    /// crowded it.
    private var columnArtEdge: CGFloat? {
        guard columnSize.width > 0 else { return nil }
        return min(columnSize.width - 56, columnSize.height * 0.4)
    }

    /// The art pane lays the names and title beside the art rather than
    /// under it: in a stacked split every art pane is wider than tall (a
    /// 475×270 strip at the head of the column), so the art takes the
    /// pane's height and the width is the text's. A side-by-side split
    /// gives a pane taller than wide and keeps the stack.
    private var namesBesideArt: Bool {
        guard style == .fullScreen else { return false }
        if #available(iOS 27.1, *) { return paneAxis != .horizontal }
        return false
    }

    /// The art on show, at the size the header draws it; the background
    /// takes its color from the same file so it is never a second fetch.
    private var artworkURL: URL? {
        model.library?.artworkURL(player.currentTrack?.thumb, size: 900)
    }

    var body: some View {
        switch style {
        case .phone:
            scrollingList
                .artworkBackground(artworkURL)
        case .column:
            // The phone's screen beside the browser: the same hierarchy,
            // scrolling the same way, half the width, and no title: the
            // art says what it is. No navigation stack in the column
            // either: beside the browser's stack on an iPhone Duo a
            // second one reserved a trailing inset the width of the
            // vertical bar, about 85pt, though the bar sits beside the
            // browser, and the column's content ran 335pt wide in a 475pt
            // column.
            scrollingList
                .artworkBackground(artworkURL)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { columnSize = $0 }
        case .fullScreen:
            // The header lives outside the List on purpose. A List row whose
            // height follows the width (the art is a square of the cover)
            // recurses in UICollectionView's layout during a live window
            // resize on the Mac; a plain VStack does not. The queue rows are
            // fixed height, so they stay in a List and keep swipe to remove.
            // The cover's own stack, so its close button is a real
            // toolbar item.
            NavigationStack {
                panes
                    .artworkBackground(artworkURL)
                    .navigationTitle("Now Playing")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Hide Now Playing", systemImage: "xmark") { presentation.isShown = false }
                        }
                    }
            }
            // The cover gives way to the column itself: a full-screen
            // presentation takes the host's view out of the window, so
            // the host never measures the window turning wide. On an
            // iPhone Duo opened from its outer display to landscape the
            // cover stayed over the whole screen, the column never came,
            // and nothing but the × closed it.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if NowPlayingPresentation.wantsColumn(size) { presentation.isShown = false }
            }
        }
    }

    /// The header scrolling with the queue, Spotify-style, so Up Next gets
    /// the whole screen rather than whatever is left under the art.
    private var scrollingList: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            queueSection
        }
        .listStyle(.plain)
    }

    /// The cover's header: the art, then the transport over the queue. An
    /// arrangement rather than a plain stack: on an iPhone Duo half folded
    /// like a laptop the fold is a horizontal division, and the split puts
    /// the art on the top pane and the controls on the bottom one, by the
    /// hands. Flat, the split follows the shape: halves stacked in the
    /// portrait cover, side by side in a cover wider than it is tall.
    @ViewBuilder private var panes: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                // Under half of a stacked split: in a 669pt cover that is
                // art of about 220 beside the names and two queue rows
                // under the transport; a tall cover caps the art at 400
                // anyway.
                artPane
                    .splitArrangementLayoutRatio(idealHorizontal: 0.5, idealVertical: 0.45)
                    .background {
                        SplitAxisProbe { paneAxis = $0 }
                    }
            } secondary: {
                VStack(spacing: 0) {
                    controlsPane
                    queueList
                }
            }
            .arrangementViewStyle(.split)
        } else {
            VStack(spacing: 0) {
                artPane
                controlsPane
                queueList
            }
        }
    }

    /// The queue on its own, under the pinned header.
    private var queueList: some View {
        List { queueSection }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The transport above is the gap; the list's own top inset
            // cost a row in a 669pt column.
            .contentMargins(.top, 0, for: .scrollContent)
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
                .rowContextMenu { TrackMenu(model: model, track: entry.item, placement: .queued(entry)) }
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

    /// The phone's and the column's header row: the art block over the
    /// controls, scrolling away with the queue.
    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            artBlock
            titleRow
            controls
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// The art block as the arrangement's first pane. The art fits the
    /// pane's height as well as its width, so a pane half a folded screen
    /// tall shrinks the art rather than losing it.
    private var artPane: some View {
        Group {
            if namesBesideArt {
                // The art's edge is measured, not negotiated: the pane's
                // height, or what its width leaves after 180 for the
                // names and title, whichever is less. A stack's priority
                // sizing gave the art 140 of a 475 strip.
                GeometryReader { proxy in
                    let edge = max(0, min(proxy.size.height, proxy.size.width - 16 - 180, 400))
                    HStack(alignment: .top, spacing: 16) {
                        art(edge: edge)
                        VStack(alignment: .leading, spacing: 4) {
                            artistLine
                                .font(.headline)
                            albumLine
                                .font(.subheadline)
                            Spacer(minLength: 12)
                            titleRow
                        }
                        .frame(maxWidth: .infinity, maxHeight: edge, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else {
                artBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// The controls at the head of the queue's pane, led by the title
    /// unless it sits beside the art.
    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !namesBesideArt { titleRow }
            controls
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// The context first: whose record is on, and which, then the art.
    /// Everything is leading-aligned on the art's left edge; a centred
    /// title beside one 44pt well read as off-centre. On the phone the
    /// sheet's drag indicator sits over the top, so the text clears it.
    /// In the column the artist line sits level with the inline title
    /// of the stack beside it: 26pt lower under a vertical bar, where
    /// the window has no status bar on top.
    private var artBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                artistLine
                    .font(.headline)
                albumLine
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.top, style == .phone ? 28 : style == .column ? (navigator.hasVerticalBar ? 38 : 12) : 8)

            art(edge: style == .column ? columnArtEdge : nil)
                .padding(.horizontal, 12)
                // Centred in the column, where it no longer spans the
                // width; the names and title keep the leading edge.
                .frame(maxWidth: .infinity, alignment: style == .column ? .center : .leading)
        }
    }

    /// Edge to edge less a margin, so the art is as big as the screen
    /// allows rather than a fixed 300pt. In the column and the cover the
    /// art is capped so a wide pane in a short window still leaves room
    /// for the queue, and it gives way in height too: the square fits
    /// whatever the pane has left.
    private func art(edge: CGFloat?) -> some View {
        Artwork(url: artworkURL, size: edge, corner: 14)
            .shadow(radius: 12, y: 6)
            // A measured edge needs no cap; a flexible frame around it
            // only centred the square in the room it didn't take.
            .frame(maxWidth: style == .phone || edge != nil ? nil : 400,
                   maxHeight: style == .phone || edge != nil ? nil : 400, alignment: .leading)
            // A long press on the art is the track's menu: the way
            // to its album, and to who hears its artist.
            .contextMenu {
                if let track = player.currentTrack {
                    TrackMenu(model: model, track: track, placement: .playing)
                }
            }
    }

    /// The track itself, after the art, where the heart can sit beside
    /// it.
    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.currentTrack?.title ?? "Nothing playing")
                        .font(.title3.bold())
                        .lineLimit(3)
                    // The credited artist on a compilation or a feature;
                    // the album artist is already at the top.
                    if let credited = player.currentTrack?.trackArtist {
                        Text(credited)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The heart belongs to the track, so it sits beside the
                // title, level with its first line.
                HeartButton(model: model, track: player.currentTrack)
                    .frame(width: 44, height: 26)
        }
        .padding(.horizontal, 12)
    }

    /// The scrubber and the transport.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            scrubber
            transport
        }
    }

    /// The album artist, the one with a page to open. The credited artist
    /// on a feature or a compilation is shown under the title instead.
    @ViewBuilder private var artistLine: some View {
        let track = player.currentTrack
        let name = track?.grandparentTitle ?? ""
        if let track, let key = track.grandparentRatingKey, let artist = track.grandparentTitle {
            routeLink(name, label: "Open \(artist)") {
                navigator.open(.artist(ArtistRoute(ratingKey: key, title: artist)))
            }
        } else {
            Text(name)
        }
    }

    @ViewBuilder private var albumLine: some View {
        let track = player.currentTrack
        let name = track?.parentTitle ?? ""
        if let album = track?.album {
            routeLink(name, label: "Open \(album.title)") { navigator.open(.album(album)) }
                .foregroundStyle(.secondary)
        } else {
            Text(name).foregroundStyle(.secondary)
        }
    }

    /// A name with a caret that opens its page. The cover gets out of the
    /// way first; the column stays put.
    private func routeLink(_ name: String, label: String, open: @escaping () -> Void) -> some View {
        Button {
            if !presentation.isColumn { presentation.isShown = false }
            open()
        } label: {
            HStack(spacing: 4) {
                Text(name).lineLimit(2)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Once the queue has ended the only sensible action is to start over,
    /// so the play button becomes a restart and the rest dims.
    private var transport: some View {
        let ended = player.hasEnded
        let dimmed = ended ? 0.35 : 1.0
        return HStack(spacing: 28) {
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
        .frame(maxWidth: .infinity)
        // AirPlay is an output control, so it rides with the transport, as
        // an overlay rather than a fourth member so play stays centred.
        .overlay(alignment: .trailing) {
            AirPlayButton()
                .frame(width: 44, height: 44)
                .padding(.trailing, 12)
                .accessibilityLabel("AirPlay")
        }
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
                        if let target = scrubbing { commitScrub(target) }
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
        // A backstop for `onEditingChanged(false)`, which the seek above
        // hangs on: when the slider never reports the end of a drag the
        // thumb stays parked where it was dropped and the player is
        // untouched. A thumb that has sat still this long is a seek either
        // way; one still on the playing position is a touch that hasn't
        // moved yet.
        .task(id: scrubbing) {
            guard let target = scrubbing else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            guard abs(target - player.currentTime) > 1 else {
                scrubbing = nil
                return
            }
            commitScrub(target)
        }
    }

    /// The thumb stays pinned until the seek lands: released at once it
    /// flashed back to the old time for the length of the seek. A drag
    /// begun in the meantime has moved `scrubbing` and keeps it.
    private func commitScrub(_ target: Double) {
        player.seek(to: target) {
            if scrubbing == target { scrubbing = nil }
        }
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
                // The glyph is 22pt; the tap target is not.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
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

/// Reports which way a split arrangement laid out the pane it sits in.
@available(iOS 27.1, *)
private struct SplitAxisProbe: View {
    let report: (Axis?) -> Void
    @Environment(\.splitArrangementAxis) private var axis

    var body: some View {
        Color.clear.onChange(of: axis, initial: true) { _, axis in report(axis) }
    }
}
