import SwiftUI

/// Album or artist art, served pre-resized by Plex's photo transcoder and
/// cached by `ImageLoader`.
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 52
    var corner: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.35))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: url) {
            guard let url else { image = nil; return }
            // Synchronous hit avoids a placeholder flash on reused rows.
            if let hit = ImageLoader.shared.cached(url) { image = hit; return }
            image = nil
            image = await ImageLoader.shared.image(for: url)
        }
    }
}
