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
    @Namespace private var glass
    /// The home indicator inset under the bar. The stack ignores the
    /// keyboard's safe area, so this never includes it.
    @State private var bottomInset: CGFloat = 0
    /// How much of the screen the keyboard covers, from its own
    /// notifications, so the bar tracks it whatever screen was on top.
    @State private var keyboardHeight: CGFloat = 0
    /// A hardware keyboard's accessory strip is short; anything taller
    /// is the real thing.
    private var keyboardUp: Bool { keyboardHeight > 60 }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // In a wide window the column is always up, and the pill
                // would only duplicate its transport.
                if let track = player.currentTrack, !nowPlaying.isColumn {
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
                            .frame(width: 52, height: 52)
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
        // Tighter to the edges while the keyboard is up: the field wants
        // the width, and the keyboard's own margins already frame it.
        .padding(.horizontal, keyboardUp ? 12 : 20)
        // Pulled into the home-indicator inset so the gap below the pills is
        // a little more than the 20pt at their sides. With the keyboard up
        // the pills sit a fixed gap above its top edge instead.
        .padding(.bottom, keyboardUp ? keyboardHeight - bottomInset + 8 : 26 - bottomInset)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.safeAreaInsets.bottom, initial: true) { _, inset in
                    bottomInset = inset
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            // Screen coordinates: the covered part is below the frame's top.
            let bounds = UIScreen.main.bounds
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = max(0, bounds.maxY - frame.minY)
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
                    Artwork(url: model.library?.artworkURL(track.thumb), size: 32, corner: 7)
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
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(10)
        // A touch more air before the art than around it; not when the
        // pill is just the art in a circle, where it would sit off-centre.
        .padding(.leading, compact ? 0 : 4)
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
                .frame(height: 52)
                .contentShape(.capsule)
            } else {
                Button {
                    searching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(filtering ? .bold : .regular))
                        .foregroundStyle(filtering ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.primary))
                        .frame(width: 52, height: 52)
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
