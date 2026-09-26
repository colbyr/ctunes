import SwiftUI
import WidgetKit

/// What stands for a mix on a widget: the saved thumb (round for an
/// artist), the heart disc for the favorites, the album stack for a mix
/// of several picks, a glyph where the thumb hasn't been saved. The
/// drawing of `MixArt` on the Music screen, over files instead of URLs.
struct CardArt: View {
    let card: WidgetFeed.Card
    let size: CGFloat

    var body: some View {
        switch card.art {
        case .favorites:
            disc("heart.fill", ink: .heartInk, fill: .heart)
        case .mix:
            disc("square.stack", ink: .mix, fill: .mix.opacity(0.16))
        case .artist:
            picture(placeholder: "music.microphone").clipShape(.circle)
        case .playlist:
            picture(placeholder: "music.note.list")
        case .album:
            picture(placeholder: "opticaldisc")
        }
    }

    private func disc(_ symbol: String, ink: Color, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(size >= 48 ? .title2 : .body)
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: .circle)
    }

    @ViewBuilder
    private func picture(placeholder: String) -> some View {
        if let url = card.thumbURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 6))
        } else {
            Image(systemName: placeholder)
                .font(size >= 48 ? .title2 : .body)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.divider, in: .rect(cornerRadius: 6))
        }
    }
}

extension WidgetFeed.Card {
    /// The style glyph's color, as on the Music screen.
    var accentColor: Color {
        switch accent {
        case .heart: .heart
        case .playlist: .playlist
        case .amber: .accentText
        case .mix: .mix
        }
    }
}

/// The parchment, washed at the top with the art's tint when the card
/// has one, as the album page is.
struct WidgetGround: View {
    let tint: ArtworkTint?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.parchmentTop, .parchmentBottom], startPoint: .top, endPoint: .bottom)
            if let tint {
                LinearGradient(
                    stops: [
                        .init(color: tint.wash, location: 0),
                        .init(color: tint.wash.opacity(0.6), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }
}
