import PlexKit
import SwiftUI

/// One album or artist as the browse screens draw it: a tile for the grid
/// layout, a row for the list. The root, the artist page and the mix
/// pools all draw from here so an album reads the same everywhere.

/// The grid for a pane this wide: three across under 560, a fixed count
/// rather than a floor, so a phone, and the page beside the Now Playing
/// column on a Duo whether it is bent (about 375pt) or flat (about 460),
/// all read three; a floor of 100 put four on the flat Duo and three on
/// the bent one, and the fold between them reflowed the grid. Four
/// across from 560, which is the Duo's inner display
/// upright (669pt), where 180 left three tiles of 200; from 720 the
/// floor rises so an iPad or a Mac window doesn't pack thumbnails. By
/// width, not size class: a regular-width pane can be narrower than a
/// phone.
enum BrowseTile {
    static func columns(forWidth width: CGFloat) -> [GridItem] {
        guard width >= 560 else {
            return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        }
        return [GridItem(.adaptive(minimum: width >= 720 ? 180 : 136), spacing: 12, alignment: .top)]
    }
}

/// One cover with its title and either the artist or the year under it.
struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum
    let showArtist: Bool

    var body: some View {
        let state = model.downloads.state(album)
        let playable = model.downloads.hasDownloads(album)
        let offline = model.connection == .unreachable
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) { DownloadBadge(state: state) }
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.footnote)
                    .lineLimit(1)
                // An Apple Music album leads its line with the mark.
                (album.isAppleMusic
                    ? AppleMusicMark.text(album.subtitle(showArtist: showArtist))
                    : Text(album.subtitle(showArtist: showArtist)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Browsable but not playable: still in the grid, clearly dimmed.
        .opacity(offline && !playable ? 0.35 : 1)
        .accessibilityHint(album.isAppleMusic ? "From Apple Music" : "")
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
            dimmed: model.connection == .unreachable && !model.downloads.hasDownloads(album),
            appleMusic: album.isAppleMusic,
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

/// One composite with the title and the counts under it, for the root's
/// Playlists subject. A smart playlist's list counts are stale (measured
/// off by up to half), so it says "Smart playlist" and no count.
struct PlaylistTile: View {
    let model: AppModel
    let playlist: PlexPlaylist

    var body: some View {
        let offline = model.connection == .unreachable
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: model.library?.artworkURL(playlist.composite), size: nil, corner: 8, placeholder: "music.note.list")
                .artworkShadow()
                .overlay(alignment: .bottomTrailing) { DownloadBadge(state: model.downloads.state(playlist)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(offline && !model.downloads.hasDownloads(playlist) ? 0.35 : 1)
        .contentShape(.rect)
    }
}

/// The favorites among the playlists: the one list the server keeps as
/// ratings rather than a playlist, drawn as a tile so the page reaches it
/// with or without a shortcut. The heart disc stands in for a composite.
struct FavoritesTile: View {
    /// How many are hearted, or nil until the count lands.
    let count: Int?
    var download: DownloadState = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FavoritesArt(size: nil, corner: 8)
                .artworkShadow(soft: true)
                .overlay(alignment: .bottomTrailing) { DownloadBadge(state: download) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Favorites")
                    .font(.footnote)
                    .lineLimit(1)
                Text(count.map(PlexPlaylist.trackCount) ?? "Hearted tracks")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// The New Playlist item's art: an empty sleeve, a dashed outline with
/// an amber plus, so it reads as a place to make one rather than one.
struct NewPlaylistArt: View {
    let size: CGFloat?
    let corner: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.6), style: .init(lineWidth: 1.5, dash: [4, 4]))
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: proxy.size.width * 0.32, weight: .light))
                                .foregroundStyle(Color.accentText)
                        }
                }
            }
    }
}

/// New Playlist as the tile before the favorites'.
struct NewPlaylistTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NewPlaylistArt(size: nil, corner: 8)
            Text("New Playlist").font(.footnote.weight(.medium)).foregroundStyle(Color.accentText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

struct NewPlaylistRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NewPlaylistArt(size: BrowseRow<EmptyView, EmptyView>.artSize, corner: 6)
                Text("New Playlist").font(.body.weight(.medium)).foregroundStyle(Color.accentText).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The same as a row, the list layout's shape without the `···`: the
/// favorites have no menu, their page has the download.
struct FavoritesRow: View {
    let count: Int?
    var download: DownloadState = .none
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FavoritesArt(size: BrowseRow<EmptyView, EmptyView>.artSize, corner: 6)
                    .artworkShadow(soft: true)
                    .overlay(alignment: .bottomTrailing) { DownloadBadge(state: download).padding(-3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Favorites")
                        .font(.body)
                        .lineLimit(1)
                    Text(count.map(PlexPlaylist.trackCount) ?? "Hearted tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A heart on the heart's own wash, the size of a cover.
struct FavoritesArt: View {
    let size: CGFloat?
    let corner: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    // On an opaque ground: over a see-through wash the
                    // art's shadow fell from the glyph rather than the
                    // square.
                    Rectangle()
                        .fill(Color.parchmentTop)
                        .overlay(Rectangle().fill(Color.heart.opacity(0.16)))
                        .overlay {
                            Image(systemName: "heart.fill")
                                .font(.system(size: proxy.size.width * 0.4))
                                .foregroundStyle(Color.heart)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// The same playlist as a row.
struct PlaylistRow<Menu: View>: View {
    let model: AppModel
    let playlist: PlexPlaylist
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        BrowseRow(
            url: model.library?.artworkURL(playlist.composite),
            placeholder: "music.note.list",
            title: playlist.title,
            subtitle: playlist.subtitle,
            download: model.downloads.state(playlist),
            dimmed: model.connection == .unreachable && !model.downloads.hasDownloads(playlist),
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
    var placeholder = "music.note"
    /// Art drawn in place of the image, for a row with none to load:
    /// the favorites' heart.
    var art: AnyView? = nil
    let title: String
    let subtitle: String?
    var download: DownloadState = .none
    var dimmed = false
    /// From Apple Music: the line under the title leads with the mark.
    var appleMusic = false
    /// Off in Quick Mix, where a tap picks the item and the menu
    /// stays a long press away.
    var showsMore = true
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
            if showsMore {
                MoreButton { menu() }
            }
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
            Group {
                if let art {
                    art
                } else {
                    Artwork(url: url, size: Self.artSize, corner: 6, placeholder: placeholder)
                }
            }
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
                    (appleMusic ? AppleMusicMark.text(subtitle) : Text(subtitle))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(appleMusic ? "\(subtitle), from Apple Music" : subtitle)
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
    init(url: URL?, round: Bool = false, placeholder: String = "music.note", title: String, subtitle: String?,
         download: DownloadState = .none, dimmed: Bool = false, appleMusic: Bool = false,
         action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> Menu) {
        self.init(url: url, round: round, placeholder: placeholder, title: title, subtitle: subtitle, download: download,
                  dimmed: dimmed, appleMusic: appleMusic, action: action, accessory: { EmptyView() }, menu: menu)
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

extension PlexPlaylist {
    /// "12 tracks · 48 min" from the list's own counts for a regular
    /// playlist; "Smart playlist" alone for a smart one, whose list counts
    /// the server doesn't keep fresh.
    var subtitle: String {
        guard !smart else { return "Smart playlist" }
        var parts = [Self.trackCount(leafCount ?? 0)]
        if let duration, duration > 0 { parts.append(Self.length(milliseconds: duration)) }
        return parts.joined(separator: " · ")
    }

    /// What a swipe on a smart playlist, or one of its tracks, explains.
    static let smartEditNotice = "Smart playlists can only be modified in Plex"

    static func trackCount(_ count: Int) -> String {
        "\(count) track\(count == 1 ? "" : "s")"
    }

    /// "48 min", "1 hr 12 min", "3 hr".
    static func length(milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}
