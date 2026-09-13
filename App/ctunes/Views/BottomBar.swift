import PlexKit
import SwiftUI

/// How much of the window the software keyboard covers. The bottom bar
/// reads it from the keyboard's own notifications and `LibraryView` shares
/// it, since the stack ignores the keyboard's safe area: a screen whose
/// content must clear the keyboard adds this itself.
@MainActor @Observable
final class KeyboardInset {
    var height: CGFloat = 0
    /// A hardware keyboard's accessory strip is short; anything taller
    /// is the real thing.
    var isUp: Bool { height > 60 }
}

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
    @Environment(KeyboardInset.self) private var keyboard
    /// The window the bar sits in, for converting the keyboard's
    /// screen-space frame; `UIScreen.main` is gone.
    @State private var window: UIWindow?
    private var keyboardUp: Bool { keyboard.isUp }

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
        .padding(.bottom, keyboardUp ? keyboard.height - bottomInset + 8 : 26 - bottomInset)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.safeAreaInsets.bottom, initial: true) { _, inset in
                    bottomInset = inset
                }
            }
        }
        .background { WindowReader { window = $0 } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let window, let screen = window.windowScene?.screen,
                  let screenFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            // The frame is in screen coordinates. Through the screen's
            // space, not `window.convert(_:from: nil)`, which takes it as
            // the window's own and is off for a window not at the screen's
            // origin (Split View, Stage Manager, a Mac).
            let frame = screen.coordinateSpace.convert(screenFrame, to: window.coordinateSpace)
            let covered = frame.intersection(window.bounds)
            // Only a keyboard docked along the bottom edge lifts the bar.
            // Measuring from the frame's top alone, the zero frame an
            // undocked or floating keyboard reports read as covering the
            // whole window and sent the bar to the top of the screen.
            let height = covered.isNull || covered.maxY < window.bounds.maxY - 1 ? 0 : covered.height
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboard.height = height
            }
        }
        // Belt and braces: a hide always lands the bar, and a keyboard
        // that went away with the app never posts its frame change.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) { keyboard.height = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            keyboard.height = 0
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
        // A long press is the playing track's menu, the same one the art
        // in Now Playing has.
        .contextMenu { TrackMenu(model: model, track: track, placement: .playing) }
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
                    TextField("Artists, Albums and Songs", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { focused = false }
                        // A fresh search wants the keyboard; the pill
                        // reopening over kept results (back from an album
                        // opened from them) wants the results.
                        .onAppear { if query.isEmpty { focused = true } }
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
    }
}

/// Hands the view's window to `onWindow` once it is attached.
private struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> View { View(onWindow: onWindow) }
    func updateUIView(_ view: View, context: Context) { view.onWindow = onWindow }

    final class View: UIView {
        var onWindow: (UIWindow?) -> Void

        init(onWindow: @escaping (UIWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow(window)
        }
    }
}
