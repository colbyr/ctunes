import SwiftUI

/// The iPhone Duo half folded like a laptop: the fold runs across the
/// inner display, and a page's header fills the top half so the browser
/// (the filter bar, the rows, the grid) starts just under the crease, by
/// the hands. Only a fold that is *active* counts: iOS 27.1 places the
/// division while the device is flat too (`includeInactive`), and flat
/// the page reads as one screen.
///
/// The crease is read on the scroll view, whose frame doesn't move as the
/// content scrolls, and handed to its content as an offset from the top
/// of the scroll content; the header pads itself down to it once, at
/// rest, and scrolls away with everything else.
extension EnvironmentValues {
    /// How far below the top of the scroll content a horizontal crease
    /// runs, while the device is half folded. Nil anywhere else.
    @Entry var creaseOffset: CGFloat?
}

extension View {
    /// Reads an active horizontal fold off this scroll view and hands it
    /// to the content as `creaseOffset`.
    func readsCrease() -> some View { modifier(CreaseReader()) }

    /// Holds a header at least down to the crease, its content centred in
    /// the top half, when the device is half folded. `above` is how far
    /// down the scroll content the header starts, its own padding
    /// included, so the next view lands on the crease.
    func fillsToCrease(above: CGFloat = 0, below: CGFloat = 0) -> some View {
        modifier(CreaseFill(above: above, below: below))
    }
}

private struct CreaseReader: ViewModifier {
    @State private var offset: CGFloat?

    func body(content: Content) -> some View {
        content
            .environment(\.creaseOffset, offset)
            .onGeometryChange(for: CGFloat?.self) { proxy in
                guard #available(iOS 27.1, *) else { return nil }
                // Active only: no `includeInactive`, so a flat device
                // reports none. Wider than tall is the laptop fold; the
                // book's runs top to bottom and splits the window instead.
                let folds = proxy.reservedRegions(kind: .division)
                guard let fold = folds.first(where: { $0.frame.width > $0.frame.height }) else { return nil }
                // The scroll content starts under the bars, whichever way
                // the proxy's frame sits relative to them.
                let offset = fold.frame.maxY - proxy.safeAreaInsets.top
                return offset > 0 ? offset.rounded() : nil
            } action: { offset = $0 }
    }
}

private struct CreaseFill: ViewModifier {
    let above: CGFloat
    let below: CGFloat
    @Environment(\.creaseOffset) private var crease

    func body(content: Content) -> some View {
        if let crease {
            content.frame(minHeight: max(0, crease - above - below), alignment: .center)
        } else {
            content
        }
    }
}

extension View {
    /// The page's title over its subtitle, centred while the bar leaves
    /// it the top bar alone (`LibraryNavigator.centersTitle(overArt:)`):
    /// the Duo on its side, and on a page led by art (`artMidX`, the
    /// art's centre in global space) the Duo closed too. A `.principal`
    /// item, which the bar centres; the native title sits at the leading
    /// edge there. The page leaves its native subtitle empty meanwhile,
    /// or it would show beside this.
    func centeredStripTitle(_ title: String, subtitle: String, overArt: Bool = false, artMidX: CGFloat? = nil) -> some View {
        modifier(CenteredStripTitle(title: title, subtitle: subtitle, overArt: overArt, artMidX: artMidX))
    }

    /// Shifts a bar item so its centre sits at `x` in global space. The
    /// bar centres a `.principal` item over its own width, which runs
    /// ~10pt into the strip beside the page, so a title centred by the
    /// bar sat off the art under it. The shift is capped so a measurement
    /// gone wrong can't push the title far.
    func centred(onX x: CGFloat?) -> some View {
        modifier(CentredOnX(x: x))
    }

    /// Reports the view's centre in global space, for `centred(onX:)`.
    func reportsMidX(_ midX: Binding<CGFloat?>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { midX.wrappedValue = $0 }
    }
}

private struct CenteredStripTitle: ViewModifier {
    let title: String
    let subtitle: String
    let overArt: Bool
    let artMidX: CGFloat?
    @Environment(LibraryNavigator.self) private var navigator

    func body(content: Content) -> some View {
        content.toolbar {
            if navigator.centersTitle(overArt: overArt) {
                ToolbarItem(placement: .principal) {
                    BarTitle(title: title, subtitle: subtitle)
                        .centred(onX: artMidX)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}

private struct CentredOnX: ViewModifier {
    let x: CGFloat?
    /// The shift applied so far, corrected by what is left to go each
    /// time the item is measured. The bar re-centres an offset item, so
    /// the measurement includes the shift: a plain `x - midX` flipped
    /// between two values on every pass. Accumulating converges whether
    /// the measurement includes the shift or not.
    @State private var shift: CGFloat = 0
    @State private var midX: CGFloat?

    func body(content: Content) -> some View {
        content
            .reportsMidX($midX)
            .offset(x: shift)
            .onChange(of: midX) { _, _ in correct() }
            .onChange(of: x) { _, _ in correct() }
    }

    private func correct() {
        guard let x, let midX else { return }
        let next = max(-24, min(24, shift + x - midX))
        if abs(next - shift) > 0.5 { shift = next }
    }
}

/// The page's title over its subtitle, drawn to match the bar's own
/// inline title and subtitle, for the places a page draws them itself:
/// centred over the bar on a Duo lying on its side, and the album page's
/// title, whose artist line opens the artist.
struct BarTitle: View {
    let title: String
    let subtitle: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: -1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
    }
}

extension View {
    /// Reports how far the page's safe area runs in from each side to
    /// `LibraryNavigator.pageInsets`. A vertical strip insets the pages
    /// inside the stack, but on a side with no hardware inset (the Duo
    /// split with the app on the left, the strip down its left edge) the
    /// window's safe area doesn't carry it, so the bottom bar, which sits
    /// outside the stack, can't see it there without this.
    func reportsPageInsets() -> some View { modifier(PageInsetsReporter()) }
}

private struct PageInsetsReporter: ViewModifier {
    @Environment(LibraryNavigator.self) private var navigator

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: HorizontalInsets.self) { proxy in
                    HorizontalInsets(leading: proxy.safeAreaInsets.leading,
                                     trailing: proxy.safeAreaInsets.trailing)
                } action: { navigator.pageInsets = $0 }
        }
    }
}

/// A view's safe-area insets on its two sides.
struct HorizontalInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}
