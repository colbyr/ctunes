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
