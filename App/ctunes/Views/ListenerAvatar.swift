import PlexKit
import SwiftUI

/// The colors a listener can pick from. `Listener.colorIndex` indexes this
/// list, so the order is part of the stored data: append, don't reorder.
enum ListenerPalette {
    static let colors: [Color] = [.purple, .green, .orange, .teal, .pink, .indigo, .red, .mint]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// A colored disc with the listener's initial. `struck` draws the diagonal
/// line the album screen uses for "not for this person".
struct ListenerAvatar: View {
    let listener: Listener
    var size: CGFloat = 24
    var struck = false

    var body: some View {
        ZStack {
            Circle().fill(ListenerPalette.color(listener.colorIndex))
            Text(listener.initial)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
            if struck {
                Path { path in
                    path.move(to: CGPoint(x: size * 0.18, y: size * 0.82))
                    path.addLine(to: CGPoint(x: size * 0.82, y: size * 0.18))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The owner's stand-in. There is no Plex username to take an initial from.
struct OwnerAvatar: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(.tint)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
