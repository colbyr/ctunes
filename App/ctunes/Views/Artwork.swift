import PlexKit
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
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            // Synchronous hit avoids a placeholder flash on reused rows.
            if let hit = ImageLoader.shared.cached(url) { image = hit; return }
            image = nil
            image = await ImageLoader.shared.image(for: url)
        }
    }
}

/// The download mark in the corner of album art and artist portraits,
/// shared by every tile, cover and portrait so it reads the same
/// everywhere. A white arrow on a dark disc when every track is down; a
/// dotted ring around it while a pin is still coming down (an exclamation
/// mark once it has stalled); a half ring when some tracks are down and
/// nothing is on its way. Nothing at all with no files.
struct DownloadBadge: View {
    let state: DownloadState
    /// For the full-size cover on an album page or the portrait on an
    /// artist's.
    var large = false

    var body: some View {
        if state.hasFiles || state.isDownloading {
            let size: CGFloat = large ? 26 : 15
            let line: CGFloat = large ? 2 : 1.5
            ZStack {
                Circle().fill(.black.opacity(0.55))
                switch state {
                case .downloading(_, _, let stalled):
                    Circle()
                        .inset(by: line / 2)
                        .stroke(.white, style: .init(lineWidth: line, dash: [line, line * 1.4]))
                    Image(systemName: stalled ? "exclamationmark" : "arrow.down")
                        .font(.system(size: size * 0.55, weight: .bold))
                case .partial:
                    Circle()
                        .inset(by: line / 2)
                        .trim(from: 0, to: 0.5)
                        .stroke(.white, style: .init(lineWidth: line, lineCap: .round))
                    Image(systemName: "arrow.down")
                        .font(.system(size: size * 0.55, weight: .bold))
                case .complete, .none:
                    Image(systemName: "arrow.down")
                        .font(.system(size: size * 0.55, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .padding(large ? 10 : 5)
            .accessibilityLabel(Self.label(state))
        }
    }

    static func label(_ state: DownloadState) -> String {
        switch state {
        case .none: ""
        case .downloading(let done, let total, let stalled):
            stalled ? "Download stalled, \(done) of \(total) tracks" : "Downloading, \(done) of \(total) tracks"
        case .partial(let done, let total): "\(done) of \(total) tracks downloaded"
        case .complete: "Downloaded"
        }
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
