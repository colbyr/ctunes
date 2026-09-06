import PlexKit
import SwiftUI

/// Floating pills along the bottom edge: the mini player on the left, search
/// on the right. Activating search grows its pill into a text field, adds a
/// close pill beyond it and shrinks the mini player down to its artwork so
/// the three share the width.
struct BottomBar: View {
    let model: AppModel
    @Binding var query: String
    @Binding var searching: Bool
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var glass
    /// The inset under the bar: the home indicator, or the keyboard.
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                // On a regular width the pill is only the way back to the
                // column: while that is open it would duplicate the transport.
                if let track = player.currentTrack, !(sizeClass == .regular && nowPlaying.isShown) {
                    MiniPlayerPill(model: model, track: track, compact: searching) {
                        nowPlaying.isShown = true
                    }
                    .glassEffectID("player", in: glass)
                }
                SearchPill(query: $query, searching: $searching)
                    .glassEffectID("search", in: glass)
                if searching {
                    Button {
                        query = ""
                        searching = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 60, height: 60)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("close", in: glass)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        // Pulled into the home-indicator inset so the gap below the pills is
        // a little more than the 20pt at their sides. Not when the keyboard is up: that inset
        // is the keyboard, and the bar would sit on its top edge.
        .padding(.bottom, bottomInset > 60 ? 0 : 26 - bottomInset)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.safeAreaInsets.bottom, initial: true) { _, inset in
                    bottomInset = inset
                }
            }
        }
        .animation(.bouncy(duration: 0.4), value: searching)
        .animation(.bouncy(duration: 0.4), value: player.currentTrack == nil)
        .animation(.bouncy(duration: 0.4), value: nowPlaying.isShown)
    }
}

private struct MiniPlayerPill: View {
    let model: AppModel
    let track: PlexTrack
    let compact: Bool
    let open: () -> Void
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Artwork(url: model.library?.artworkURL(track.thumb), size: 44, corner: 22)
                    if !compact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text(track.grandparentTitle ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if !compact {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 34, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(8)
        .padding(.trailing, compact ? 0 : 8)
        // Plain buttons only hit-test their opaque content, so without this
        // a tap in the padding lands on the list row underneath the pill.
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct SearchPill: View {
    @Binding var query: String
    @Binding var searching: Bool
    @FocusState private var focused: Bool

    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Artists and albums", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onAppear { focused = true }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .contentShape(.capsule)
            } else {
                Button {
                    searching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(filtering ? .bold : .regular))
                        .foregroundStyle(filtering ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.primary))
                        .frame(width: 60, height: 60)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        // Keyboard dismissed with nothing typed: nothing to keep open.
        .onChange(of: focused) { _, isFocused in
            if !isFocused && !filtering { query = ""; searching = false }
        }
    }
}
