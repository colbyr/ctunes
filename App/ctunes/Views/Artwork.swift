import PlexKit
import SwiftUI

/// Album or artist art, served pre-resized by Plex's photo transcoder and
/// cached by `ImageLoader`.
struct Artwork: View {
    let url: URL?
    /// Fixed edge length, or nil to fill the available width as a square.
    var size: CGFloat? = 52
    var corner: CGFloat = 6
    /// The glyph on the parchment while there is no image: a note for a
    /// cover, a list for a playlist with no composite yet.
    var placeholder = "music.note"

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
                            Image(systemName: placeholder)
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
/// everywhere: a white glyph on a glass disc tinted dark, so it holds up
/// on white art, ringed by the download's progress. One drawing per
/// state, the same on the badge, the cover's button, and the menus:
///
/// - nothing down: a bare arrow (the cover only; a tile shows no mark)
/// - downloading: a stop square inside a ring that fills clockwise
/// - waiting (the server away or every fetch failed): a dotted ring
///   around the arrow, `arrow.down.circle.dotted`'s shape
/// - partial, nothing on its way: the arrow inside the ring at how far
///   it got
/// - complete: a check mark inside the whole ring
struct DownloadMark: View {
    let state: DownloadState
    let size: CGFloat

    var body: some View {
        let line = size >= 28 ? 2 : 1.5
        ZStack {
            switch state {
            case .none:
                glyph("arrow.down")
            case .downloading(_, _, true):
                Circle()
                    .inset(by: line / 2)
                    .stroke(.white, style: .init(lineWidth: line, dash: [line, line * 1.4]))
                glyph("arrow.down")
            case .downloading(_, _, false):
                ring(line: line)
                glyph("stop.fill", scale: 0.36)
            case .partial:
                ring(line: line)
                glyph("arrow.down")
            case .complete:
                ring(line: line)
                glyph("checkmark")
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
    }

    private func glyph(_ name: String, scale: CGFloat = 0.5) -> some View {
        Image(systemName: name)
            .font(.system(size: size * scale, weight: .bold))
    }

    /// A faint track with the filled arc on top, clockwise from twelve.
    private func ring(line: CGFloat) -> some View {
        ZStack {
            Circle()
                .inset(by: line / 2)
                .stroke(.white.opacity(0.35), lineWidth: line)
            Circle()
                .inset(by: line / 2)
                .trim(from: 0, to: state.progress ?? 0)
                .stroke(.white, style: .init(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.default, value: state.progress)
        }
    }
}

/// `DownloadMark` on its glass disc, in the corner of a tile, cover or
/// portrait. Nothing at all with no files and nothing on the way.
struct DownloadBadge: View {
    let state: DownloadState
    /// For the full-size cover on an album page or the portrait on an
    /// artist's.
    var large = false

    var body: some View {
        if state.hasFiles || state.isDownloading {
            let size: CGFloat = large ? 28 : 16
            DownloadMark(state: state, size: size)
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: .circle)
                .padding(large ? 10 : 5)
                .accessibilityLabel(Self.label(state))
        }
    }

    static func label(_ state: DownloadState) -> String {
        switch state {
        case .none: ""
        case .downloading(let done, let total, let stalled):
            stalled ? "Waiting to download, \(done) of \(total) tracks" : "Downloading, \(done) of \(total) tracks"
        case .partial(let done, let total): "\(done) of \(total) tracks downloaded"
        case .complete: "Downloaded"
        }
    }
}

/// The corner of the cover on an album page and the portrait on an
/// artist's: the badge, and before anything is down the bare arrow on
/// the same disc. Tapping does what the mark shows: the arrow starts the
/// whole download (partial included), the stop square stops it, the
/// dotted ring cancels the wait, and the check mark asks before removing
/// the download. Nothing offline, where there is no server to fetch from.
struct DownloadOverlay: View {
    let state: DownloadState
    let offline: Bool
    let download: () -> Void
    let remove: @MainActor () -> Void
    @State private var confirming: DownloadRemoval?

    var body: some View {
        if offline {
            DownloadBadge(state: state, large: true)
        } else {
            Button {
                switch state {
                case .none, .partial: download()
                case .downloading(_, _, false): remove()
                case .downloading(_, _, true): confirming = DownloadRemoval(cancels: true, action: remove)
                case .complete: confirming = DownloadRemoval(action: remove)
                }
            } label: {
                DownloadMark(state: state, size: 28)
                    .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .circle)
                    .padding(10)
            }
            .buttonStyle(.plain)
            // The hit area, not the disc: the padding above is inside it.
            .contentShape(.circle)
            .accessibilityLabel(Self.label(state))
            .removeDownloadConfirmation($confirming)
        }
    }

    static func label(_ state: DownloadState) -> String {
        switch state {
        case .none, .partial: "Download"
        case .downloading(_, _, true): "Cancel download"
        case .downloading(_, _, false): "Stop download"
        case .complete: "Remove download"
        }
    }
}

/// The mark at a track row's trailing edge, beside the heart: a check
/// once the file is down, the arrow in a ring while it is on its way,
/// dotted while it waits. Keeps its slot when off so the duration column
/// doesn't shift as files come and go.
struct TrackDownloadGlyph: View {
    let state: DownloadState

    var body: some View {
        let shown = state != .none
        Image(systemName: Self.symbol(state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            .accessibilityLabel(DownloadBadge.label(state))
    }

    static func symbol(_ state: DownloadState) -> String {
        switch state {
        case .none, .partial: "arrow.down.circle"
        case .downloading(_, _, true): "arrow.down.circle.dotted"
        case .downloading(_, _, false): "arrow.down.circle"
        case .complete: "checkmark.circle.fill"
        }
    }
}

/// A remove that the menus and the cover's mark ask about first: the
/// one dialog, so the wording matches wherever it comes from. `cancels`
/// is a download still waiting: the same unpin, worded as giving up on
/// the rest rather than removing what is there.
struct DownloadRemoval: Identifiable, Equatable {
    let id = UUID()
    var cancels = false
    let action: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// The dialog over a pending removal; the request is cleared by the
    /// presentation, so the modifier keeps its own copy for the action.
    func removeDownloadConfirmation(_ removal: Binding<DownloadRemoval?>) -> some View {
        modifier(RemoveDownloadConfirmation(removal: removal))
    }
}

/// Keeps the removal the dialog acts on, since the presentation clears
/// the request before the button's action runs.
private struct RemoveDownloadConfirmation: ViewModifier {
    @Binding var removal: DownloadRemoval?
    @State private var pending: DownloadRemoval?

    func body(content: Content) -> some View {
        content
            .onChange(of: removal) { _, removal in
                if let removal { pending = removal }
            }
            .confirmationDialog(
                pending?.cancels == true ? "Cancel download?" : "Remove download?",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                titleVisibility: .visible
            ) {
                Button(pending?.cancels == true ? "Cancel Download" : "Remove Download", role: .destructive) {
                    pending?.action()
                }
            } message: {
                Text(pending?.cancels == true
                     ? "The tracks still waiting are no longer downloaded; any already down are kept in the play cache."
                     : "The files are removed from this device. Nothing is removed from your library.")
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
