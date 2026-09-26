import SwiftUI
import UIKit

/// The color a piece of art is mostly made of, for the ground behind it.
/// Stored as plain channels so it is `Sendable` and can be computed off
/// the main actor. Compiled into the app and the widget extension, which
/// reads it from the feed the app writes, so a widget's ground is the
/// card's.
struct ArtworkTint: Equatable, Hashable, Codable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// The tint blended into the ground: enough to read as the cover's
    /// color, light enough for ink text on it by day and cream text by
    /// night. Saturation is pulled down a little either way, so a neon
    /// sleeve doesn't turn the whole screen into a highlighter.
    var wash: Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let ground: (Double, Double, Double) = dark ? (0x1E / 255, 0x18 / 255, 0x14 / 255) : (1, 1, 1)
            let amount = dark ? 0.52 : 0.48
            let grey = (red + green + blue) / 3
            func mix(_ channel: Double, _ groundChannel: Double) -> CGFloat {
                let desaturated = channel * 0.9 + grey * 0.1
                return CGFloat(desaturated * amount + groundChannel * (1 - amount))
            }
            return UIColor(red: mix(red, ground.0), green: mix(green, ground.1), blue: mix(blue, ground.2), alpha: 1)
        })
    }

    /// The tint as an accent for the page's controls, in the amber's
    /// place: the hue kept, pushed dark enough to read on white glass by
    /// day and bright enough for the night ground, the way the two amber
    /// values are. Nil for a sleeve with no hue to speak of (black, white,
    /// grey), where a grey accent would read as disabled and the amber
    /// looks right.
    var accent: Color? {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        guard saturation > 0.12, brightness > 0.08 else { return nil }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: hue, saturation: min(max(saturation, 0.45), 0.8), brightness: min(max(brightness, 0.82), 0.95), alpha: 1)
                : UIColor(hue: hue, saturation: min(max(saturation, 0.55), 0.95), brightness: min(max(brightness, 0.42), 0.6), alpha: 1)
        })
    }
}

extension EnvironmentValues {
    /// The accent the art on show gives the page, set by
    /// `artworkBackground(_:)` for the hero cards under it. Nil where
    /// there is no art, or none with a usable hue.
    @Entry var artworkAccent: Color?
}
