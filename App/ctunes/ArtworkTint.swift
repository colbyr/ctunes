import SwiftUI
import UIKit

/// The color a piece of art is mostly made of, for the ground behind it.
/// Stored as plain channels so it is `Sendable` and can be computed off
/// the main actor.
struct ArtworkTint: Equatable, Sendable {
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

extension UIImage {
    /// The most common color once the image is shrunk to a thumbnail,
    /// weighted toward saturated pixels so a colorful sleeve's color wins
    /// over its white border, and skipping near-black and near-white unless
    /// nothing else is left. Nil for an image that can't be drawn.
    nonisolated func dominantTint() -> ArtworkTint? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = cgImage,
              let context = CGContext(
                  data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 4 bits per channel: 4096 bins, coarse enough that a gradient
        // sky lands in one bin rather than a hundred. Each bin keeps its
        // saturation-weighted score and a plain sum for the mean color.
        struct Bin {
            var score = 0.0
            var count = 0.0
            var sum = (0.0, 0.0, 0.0)
        }
        var bins: [Int: Bin] = [:]
        var extremes: [Int: Bin] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let high = max(r, g, b)
            let low = min(r, g, b)
            let saturation = high == 0 ? 0 : (high - low) / high
            let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
            let extreme = high < 0.12 || low > 0.9
            var bin = (extreme ? extremes : bins)[key, default: Bin()]
            bin.score += 0.15 + saturation
            bin.count += 1
            bin.sum = (bin.sum.0 + r, bin.sum.1 + g, bin.sum.2 + b)
            if extreme { extremes[key] = bin } else { bins[key] = bin }
        }
        let candidates = bins.isEmpty ? extremes : bins
        guard let best = candidates.values.max(by: { $0.score < $1.score }), best.count > 0 else { return nil }
        return ArtworkTint(red: best.sum.0 / best.count, green: best.sum.1 / best.count, blue: best.sum.2 / best.count)
    }
}

/// The parchment gradient washed at the top with the art's color, fading
/// to the plain ground by the foot, with the same color handed down as
/// the page's accent. Fades between tints as the art changes.
struct ArtworkGround: ViewModifier {
    let url: URL?
    @State private var tint: ArtworkTint?

    func body(content: Content) -> some View {
        // A known tint is read straight from the cache so the first frame
        // is already the cover's color; the state only carries one that
        // had to be computed, or the last one while the next is.
        let shown = url.flatMap { ImageLoader.shared.cachedTint(for: $0) } ?? tint
        content
            .environment(\.artworkAccent, shown?.accent)
            .background {
                ZStack {
                    ParchmentBackground()
                    if let shown {
                        LinearGradient(
                            stops: [
                                .init(color: shown.wash, location: 0),
                                .init(color: shown.wash.opacity(0.6), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea()
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: shown)
            }
            .task(id: url) {
                guard let url else { tint = nil; return }
                if ImageLoader.shared.cachedTint(for: url) != nil { return }
                // Keep the old wash while the next one is computed: a track
                // change within an album shouldn't blink to white.
                let next = await ImageLoader.shared.tint(for: url)
                if !Task.isCancelled { tint = next }
            }
    }
}
