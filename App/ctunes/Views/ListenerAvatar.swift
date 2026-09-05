import PlexKit
import SwiftUI

/// The colors a listener can pick from: the Parchment secondary palette,
/// one lightness and chroma across varied hues so any pairing sits beside
/// amber. `Listener.colorIndex` indexes this list, so the order is part of
/// the stored data: append, don't reorder.
enum ListenerPalette {
    static let colors: [Color] = [
        Color(hex: 0xC9856A), // clay
        Color(hex: 0x8DA37A), // sage
        Color(hex: 0x7D93B2), // slate
        Color(hex: 0xA97C9C), // plum
        Color(hex: 0x6FA39A), // teal
        Color(hex: 0xF2B33D), // amber
    ]
    static let names = ["Clay", "Sage", "Slate", "Plum", "Teal", "Amber"]

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
            // Ink, never white: the fills are the same in both appearances.
            Text(listener.initial)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(Color.accentInk)
            if struck {
                Path { path in
                    path.move(to: CGPoint(x: size * 0.18, y: size * 0.82))
                    path.addLine(to: CGPoint(x: size * 0.82, y: size * 0.18))
                }
                .stroke(Color.ink, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
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
            Circle().fill(Color.amber)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Color.accentInk)
        }
        .frame(width: size, height: size)
    }
}
