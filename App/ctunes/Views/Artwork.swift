import SwiftUI

/// Album or artist art, served pre-resized by Plex's photo transcoder and
/// cached by `ImageLoader`.
struct Artwork: View {
    let url: URL?
    /// Fixed edge length, or nil to fill the available width as a square.
    var size: CGFloat? = 52
    var corner: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        // The square owns the size and the image is overlaid, so non-square
        // art is cropped to the square rather than stretching it.
        Color.clear
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: (size ?? 80) * 0.35))
                                .foregroundStyle(.secondary)
                        )
                }
            }
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

/// The small download mark in the corner of album art, shared by every
/// album tile so it reads the same on the browse root and in the mix pool.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(.white, .black.opacity(0.55))
            .padding(5)
    }
}

extension View {
    /// The lift under album art and artist portraits.
    func artworkShadow() -> some View {
        shadow(color: .black.opacity(0.22), radius: 5, y: 3)
    }

    /// The softer, wider lift under the hero cards. Reaches about 14pt
    /// below and 10pt to the sides, so the row holding a card needs at
    /// least that much inset or the list clips it.
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
