import SwiftUI

/// The handful of Parchment tokens the widgets use, the app's values
/// (`Theme.swift`) copied rather than shared: the app's file carries the
/// card, list and page modifiers with it.
extension Color {
    static let ink = dynamic(light: 0x2B211B, dark: 0xF5EAD6)
    static let parchmentTop = dynamic(light: 0xFFFFFF, dark: 0x1E1814)
    static let parchmentBottom = dynamic(light: 0xF9F5EE, dark: 0x151110)
    static let heart = dynamic(light: 0xD9486E, dark: 0xF07A96)
    static let heartInk = Color.white
    static let mix = dynamic(light: 0x4E6FA8, dark: 0x93ADDD)
    static let playlist = dynamic(light: 0x2E8A7F, dark: 0x7FC9BE)
    static let accentText = dynamic(light: 0x9A5F0F, dark: 0xF2B33D)
    static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF5 / 255, green: 0xEA / 255, blue: 0xD6 / 255, alpha: 0.10)
            : UIColor(red: 0x2B / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 0.12)
    })

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
