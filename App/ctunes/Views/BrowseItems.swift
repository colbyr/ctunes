import PlexKit
import SwiftUI

/// One album or artist as the browse screens draw it: a tile for the grid
/// layout, a row for the list. The root, the artist page and the mix
/// pools all draw from here so an album reads the same everywhere.

/// One cover with its title and either the artist or the year under it.
struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool

    var body: some View {
        let state = model.downloads.state(album)
        let playable = model.downloads.hasDownloads(album)
        let offline = model.state == .offline
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) { DownloadBadge(state: state) }
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(album.subtitle(showArtist: showArtist))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Browsable but not playable: still in the grid, clearly dimmed.
        .opacity(offline && !playable ? 0.35 : 1)
        .contentShape(.rect)
    }
}

/// The same album as a row. `menu` is the album's, behind the `···` and
/// the long press.
struct AlbumRow<Menu: View>: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        BrowseRow(
            url: model.library?.artworkURL(album.thumb),
            title: album.title,
            subtitle: album.subtitle(showArtist: showArtist),
            download: model.downloads.state(album),
            dimmed: model.state == .offline && !model.downloads.hasDownloads(album),
            action: action,
            menu: menu
        )
    }
}

/// One portrait with the name under it, for the root's Artists subject.
struct ArtistTile: View {
    let model: AppModel
    let artist: PlexArtist
    /// "12 albums", or nil before the albums have landed.
    let subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Artwork(url: model.library?.artworkURL(artist.thumb), size: nil, corner: 8)
                .clipShape(.circle)
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) {
                    // Pulled in toward the rim, where a circle has room.
                    DownloadBadge(state: model.downloads.state(artist: artist.ratingKey)).padding(4)
                }
            VStack(spacing: 1) {
                Text(artist.title)
                    .font(.footnote)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

/// The same artist as a row.
struct ArtistRow<Menu: View>: View {
    let model: AppModel
    let artist: PlexArtist
    let subtitle: String?
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        BrowseRow(
            url: model.library?.artworkURL(artist.thumb),
            round: true,
            title: artist.title,
            subtitle: subtitle,
            download: model.downloads.state(artist: artist.ratingKey),
            action: action,
            menu: menu
        )
    }
}

/// One row of the list layout: the art at the leading edge, a title and
/// a line under it, whatever the screen puts after them, then the `···`.
/// Like a track row, the tap target stops at the `···`, which opens the
/// same menu a long press does. The long press lifts an opaque copy of
/// the row: the default preview is a snapshot with a clear ground, and
/// the row it floats over showed through.
struct BrowseRow<Accessory: View, Menu: View>: View {
    let url: URL?
    /// A portrait rather than a cover.
    var round = false
    let title: String
    let subtitle: String?
    var download: DownloadState = .none
    var dimmed = false
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var menu: () -> Menu

    static var artSize: CGFloat { 56 }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                content.contentShape(.rect)
            }
            .buttonStyle(.plain)
            MoreButton { menu() }
        }
        .opacity(dimmed ? 0.35 : 1)
        .contextMenu { menu() } preview: {
            content
                .padding(.horizontal, 16)
                .background(Color.parchmentTop)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Artwork(url: url, size: Self.artSize, corner: 6)
                .clipShape(round ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 6)))
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) {
                    DownloadBadge(state: download).padding(round ? 0 : -3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BrowseRow where Accessory == EmptyView {
    init(url: URL?, round: Bool = false, title: String, subtitle: String?, download: DownloadState = .none, dimmed: Bool = false,
         action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> Menu) {
        self.init(url: url, round: round, title: title, subtitle: subtitle, download: download, dimmed: dimmed,
                  action: action, accessory: { EmptyView() }, menu: menu)
    }
}

/// The list layout's stack: the rows with a hairline between each pair,
/// inset past the art like the system's. A `LazyVStack` rather than a
/// `List`, since every browse screen is already a `ScrollView` and a
/// `List` on the Mac recurses on rows whose height follows the width.
struct BrowseList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color.divider)
                        .frame(height: 1)
                        .padding(.leading, BrowseRow<EmptyView, EmptyView>.artSize + 12)
                }
            }
        }
    }
}

extension PlexAlbum {
    /// The line under the title: the artist where the list mixes artists,
    /// the year where the artist is already named.
    func subtitle(showArtist: Bool) -> String {
        showArtist ? (parentTitle ?? "—") : (year.map(String.init) ?? "—")
    }
}
