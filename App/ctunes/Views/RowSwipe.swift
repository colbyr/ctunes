import SwiftUI
import UIKit

/// One action a row reveals when swiped left, for rows that live in a
/// `ScrollView` and so can't have `.swipeActions`: the album page's tracks
/// (a `ScrollView` so the cover's long press is the cover's alone) and the
/// playlists page's list layout (a `ScrollView` because a `List` recurses
/// in a Mac window's live resize).
struct RowSwipe {
    let title: String
    let systemImage: String
    let tint: Color
    var role: ButtonRole? = nil
    let action: @MainActor () -> Void
}

extension View {
    /// Swipe left to reveal the action; swipe most of the way across to
    /// run it at once. Nil leaves the row as it is.
    func rowSwipe(_ swipe: RowSwipe?) -> some View {
        modifier(RowSwipeModifier(swipe: swipe))
    }
}

private struct RowSwipeModifier: ViewModifier {
    let swipe: RowSwipe?
    @State private var offset: CGFloat = 0
    @State private var open = false
    @State private var width: CGFloat = 0

    private static let buttonWidth: CGFloat = 80

    func body(content: Content) -> some View {
        if let swipe {
            content
                .offset(x: offset)
                // Laid out in the row's own frame, so it fills exactly the
                // room the row slides out of.
                .background(alignment: .trailing) { button(swipe) }
                // A tap on the row while the action shows puts it back
                // rather than opening the row.
                .overlay(alignment: .leading) {
                    if open {
                        Color.clear
                            .contentShape(.rect)
                            .frame(width: max(width - Self.buttonWidth, 0))
                            .onTapGesture { settle(open: false) }
                    }
                }
                .gesture(HorizontalPan { translation in
                    offset = min(0, (open ? -Self.buttonWidth : 0) + translation)
                } ended: { velocity in
                    if -offset > width * 0.6 {
                        perform(swipe)
                    } else {
                        settle(open: -offset > Self.buttonWidth / 2 || velocity < -500)
                    }
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .accessibilityAction(named: swipe.title) { swipe.action() }
        } else {
            content
        }
    }

    private func button(_ swipe: RowSwipe) -> some View {
        Button(role: swipe.role) { perform(swipe) } label: {
            VStack(spacing: 4) {
                Image(systemName: swipe.systemImage).font(.body.weight(.semibold))
                Text(swipe.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: Self.buttonWidth)
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: max(-offset - 6, 0))
        .frame(maxHeight: .infinity)
        .background(swipe.tint, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .padding(.vertical, 4)
        .opacity(offset < 0 ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func settle(open: Bool) {
        withAnimation(.snappy) {
            self.open = open
            offset = open ? -Self.buttonWidth : 0
        }
    }

    private func perform(_ swipe: RowSwipe) {
        settle(open: false)
        swipe.action()
    }
}

/// A pan that only begins on a horizontal drag, so the scroll view keeps
/// every vertical one. SwiftUI's `DragGesture` can't decline a direction
/// and swallowed the scroll.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            changed(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            ended(recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
