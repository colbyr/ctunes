import SwiftUI

/// The "Parchment" palette: white ground with a breath of cream at the
/// foot, white glass, amber only where it acts, rose for hearts and a blue
/// and a teal for the two mixes. Every token carries its own light and dark
/// value, so views read `Color.ink` and never branch on the color scheme.
extension Color {
    /// Primary text, icons and filled controls.
    static let ink = dynamic(light: 0x2B211B, dark: 0xF5EAD6)
    /// Screen background gradient, top and bottom.
    static let parchmentTop = dynamic(light: 0xFFFFFF, dark: 0x1E1814)
    static let parchmentBottom = dynamic(light: 0xF9F5EE, dark: 0x151110)
    /// Cards, circular buttons and chips.
    static let glass = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.07)
            : UIColor(white: 1, alpha: 0.85)
    })
    /// The 1pt stroke on a glass surface. A hint of ink by day: on a white
    /// ground a white stroke is invisible and the card is only its shadow.
    static let glassBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 0x2B / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 0.08)
    })
    /// Hearts: the favorites disc, the heart glyphs and the favorite swipe.
    static let heart = dynamic(light: 0xD9486E, dark: 0xF07A96)
    /// The glyph on top of a heart fill.
    static let heartInk = Color.white
    /// The artist mix, and the album mix: one accent each, neither amber.
    static let artistMix = dynamic(light: 0x4E6FA8, dark: 0x93ADDD)
    static let albumMix = dynamic(light: 0x2E8A7F, dark: 0x7FC9BE)
    /// The amber fill: play, progress, the favorites disc, the owner's avatar.
    static let amber = Color(hex: 0xF2B33D)
    /// Amber as text or an icon on the cream ground, darkened for contrast;
    /// full amber on dark, where it already passes.
    static let accentText = dynamic(light: 0x9A5F0F, dark: 0xF2B33D)
    /// The glyph on top of an amber fill.
    static let accentInk = Color(hex: 0x2B211B)
    /// The soft amber circle behind the mix icons, and the icon inside it.
    static let chip = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF2 / 255, green: 0xB3 / 255, blue: 0x3D / 255, alpha: 0.16)
            : UIColor(hex: 0xFBE7BE)
    })
    static let chipInk = accentText
    /// Selected filter pills and the text on them.
    static let pill = dynamic(light: 0x2B211B, dark: 0xF5EAD6)
    static let pillInk = dynamic(light: 0xF8EFDD, dark: 0x1E1814)
    /// Hairlines.
    static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF5 / 255, green: 0xEA / 255, blue: 0xD6 / 255, alpha: 0.10)
            : UIColor(red: 0x2B / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 0.12)
    })
    /// The Now Playing pause/play disc: ink by day, amber by night.
    static let bigButton = dynamic(light: 0x2B211B, dark: 0xF2B33D)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The cream gradient behind every screen.
struct ParchmentBackground: View {
    var body: some View {
        LinearGradient(colors: [.parchmentTop, .parchmentBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

extension View {
    /// Puts the gradient behind a list and lets the rows show it.
    func parchment() -> some View {
        scrollContentBackground(.hidden)
            .background(ParchmentBackground())
            .listRowSeparatorTint(.divider)
    }

    /// The same, washed at the top with the art's own color: the album and
    /// Now Playing screens take their ground from the cover on show.
    func artworkBackground(_ url: URL?) -> some View {
        scrollContentBackground(.hidden)
            .background(ArtworkBackground(url: url))
            .listRowSeparatorTint(.divider)
    }

    /// The white-glass card surface the hero cards share.
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        background(Color.glass, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.glassBorder, lineWidth: 1))
            .cardShadow()
    }
}
