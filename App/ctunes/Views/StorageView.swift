import PlexKit
import SwiftUI

/// Where the manager's pages go on the Settings stack.
enum DownloadRoute: Hashable {
    case artist(key: String)
    case album(PlexAlbum)
}

/// The Storage page of Settings: what the app holds on the phone against
/// the phone's own capacity, the downloads by artist, album and track with
/// a way to remove any of them, and the play cache with its size. Reads
/// the inventory mirror; every row is a pin as the store holds it, so an
/// album under an artist appears on the artist's page and not here.
struct StorageList: View {
    let model: AppModel
    @Environment(AudioPlayer.self) private var player
    @State private var confirmingRemoveAll = false
    /// Bytes in the cache root; nil until read.
    @State private var cacheUsage: Int?

    private var downloads: Downloads { model.downloads }
    private var inventory: DownloadInventory { downloads.inventory }
    private var offline: Bool { model.state == .offline }

    var body: some View {
        List {
            overviewSection
            favoritesSection
            if downloads.isEmpty { emptySection } else { pinsSection; removeSection }
            cacheSection
            clearCacheSection
        }
        .settingsBackground()
        .listSectionSpacing(.compact)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("Everything kept offline will stream again. Nothing is removed from your library.")
        }
        .task { downloads.refresh() }
        // The cache moves as tracks play and as pins come and go, since a
        // pinned file leaves it and a removed one returns.
        .task(id: "\(player.currentTrack?.id ?? "")/\(downloads.generation)") {
            cacheUsage = await player.cacheUsage()
        }
    }

    // MARK: - Sections

    /// The card iPhone Storage draws, for the app: its name and what it
    /// holds, the bar, and a legend of its stores. The bar's whole is the
    /// downloads plus the cache's limit, not the phone: against a 512 GB
    /// phone every store was a sliver, and the cache's room to grow is the
    /// figure worth seeing.
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DeviceStorage.appName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text(DownloadText.bytes(downloads.usage + (cacheUsage ?? 0)))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                let favorites = favoritesBytes
                StorageBar(downloads: downloads.usage - favorites, favorites: favorites,
                           cached: cacheUsage ?? 0, cacheLimit: player.cacheLimit)
                WrappingHStack(spacing: 16, rowSpacing: 6) {
                    StorageLegend(color: .accentText, label: "Downloads", bytes: downloads.usage - favorites)
                    if inventory.favoritesPinned {
                        StorageLegend(color: .heart, label: "Favorites", bytes: favorites)
                    }
                    StorageLegend(color: .artistMix, label: "Cached", bytes: cacheUsage ?? 0)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            if offline {
                Text("Offline. Downloads resume when the server answers.")
            } else if stalled {
                Button("Retry stalled downloads") {
                    downloads.retry { await model.resumeDownloads() }
                }
            }
        }
    }

    private var emptySection: some View {
        Section {
            Text("Long-press an artist, album or track and choose Download to keep it offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// One kind of pin or another, in one list: artists and albums newest
    /// first, then tracks newest first (their list carries no dates). The
    /// art's shape and the first word of the subtitle say which is which.
    private enum Pin: Identifiable {
        case artist(DownloadInventory.ArtistPin)
        case album(DownloadInventory.AlbumPin)
        case track(PlexTrack)

        var id: String {
            switch self {
            case .artist(let pin): "artist/\(pin.key)"
            case .album(let pin): "album/\(pin.id)"
            case .track(let track): "track/\(track.ratingKey)"
            }
        }
    }

    private var pins: [Pin] {
        let dated: [(Date, Pin)] = inventory.artists.map { ($0.pinnedAt, .artist($0)) }
            + inventory.albums.map { ($0.pinnedAt, .album($0)) }
        return dated.sorted { $0.0 > $1.0 }.map(\.1) + inventory.tracks.reversed().map { .track($0) }
    }

    private var pinsSection: some View {
        Section {
            ForEach(pins) { pin in
                switch pin {
                case .artist(let artist): artistLink(artist)
                case .album(let album): albumLink(album.album)
                case .track(let track): DownloadedTrackRow(model: model, track: track, showAlbum: true)
                }
            }
        }
    }

    private var cacheSection: some View {
        Section {
            LabeledContent("Cached Tracks", value: DownloadText.bytes(cacheUsage ?? 0))
            Picker("Max Cache Size", selection: Binding(
                get: { player.cacheLimit },
                set: { player.cacheLimit = $0 }
            )) {
                ForEach(AudioPlayer.cacheLimitOptions, id: \.self) { bytes in
                    Text(DownloadText.bytes(bytes)).tag(bytes)
                }
            }
        } header: {
            SectionHeading("Cache", detail: "Recently played and upcoming tracks are kept so they don't stream twice.")
        }
    }

    @ViewBuilder private var clearCacheSection: some View {
        if let cacheUsage, cacheUsage > 0 {
            Section {
                Button(role: .destructive) {
                    Task {
                        await player.clearCache()
                        self.cacheUsage = await player.cacheUsage()
                    }
                } label: {
                    Label("Remove Cached Tracks", systemImage: "trash")
                }
                .foregroundStyle(.red)
            }
        }
    }

    /// Bytes on disk only because of the favorites pin: a favorite that is
    /// also in a downloaded album or artist counts as that download.
    private var favoritesBytes: Int {
        guard inventory.favoritesPinned else { return 0 }
        return downloads.usage(of: inventory.favorites.filter { !inventory.isTrackPinned($0) }).bytes
    }

    /// Any pin waiting out the backoff, so the retry line shows once.
    private var stalled: Bool {
        !inventory.failed.isEmpty
    }

    private func artistLink(_ pin: DownloadInventory.ArtistPin) -> some View {
        NavigationLink(value: DownloadRoute.artist(key: pin.key)) {
            DownloadRow(
                art: model.library?.artworkURL(pin.thumb ?? pin.albums.first?.thumb),
                round: true,
                title: pin.title,
                subtitle: DownloadText.summary(
                    state: downloads.state(artist: pin.key),
                    bytes: bytes(of: pin.albums),
                    unit: "album", count: pin.albums.count
                ),
                detail: "Artist"
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { downloads.unpinArtist(pin.key) } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button(role: .destructive) { downloads.unpinArtist(pin.key) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    /// One row for an album, on this page and the artist's. Swiping it
    /// away removes the album; under an artist that narrows the artist to
    /// the rest.
    private func albumLink(_ album: PlexAlbum) -> some View {
        NavigationLink(value: DownloadRoute.album(album)) {
            DownloadRow(
                art: model.library?.artworkURL(album.thumb),
                round: false,
                title: album.title,
                subtitle: DownloadText.summary(
                    state: downloads.state(album),
                    bytes: inventory.statuses[album.ratingKey]?.bytes ?? 0,
                    unit: "track", count: album.leafCount ?? inventory.statuses[album.ratingKey]?.known
                ),
                detail: ["Album", album.parentTitle].compactMap { $0 }.joined(separator: " · ")
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { downloads.unpin(album) } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button(role: .destructive) { downloads.unpin(album) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private var favoritesSection: some View {
        Section {
            Toggle("Keep Favorites Downloaded", isOn: Binding(
                get: { model.isFavoritesPinned },
                set: { on in Task { await model.setFavoritesPinned(on) } }
            ))
            .tint(Color.heart)
            .disabled(offline)
            if inventory.favoritesPinned {
                let usage = downloads.usage(of: inventory.favorites)
                LabeledContent("Favorites", value: "\(usage.files) of \(DownloadText.count(inventory.favorites.count, "track")) · \(DownloadText.bytes(usage.bytes))")
            }
        } header: {
            SectionHeading("Downloads", detail: "Downloads are available to play offline.")
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) { confirmingRemoveAll = true } label: {
                Label("Remove All Downloads", systemImage: "trash")
            }
            .foregroundStyle(.red)
        }
    }

    private func bytes(of albums: [PlexAlbum]) -> Int {
        albums.reduce(0) { $0 + (inventory.statuses[$1.ratingKey]?.bytes ?? 0) }
    }
}

/// An artist's page in the manager: their albums with what each holds.
struct DownloadedArtistPage: View {
    let model: AppModel
    let key: String
    @Environment(\.dismiss) private var dismiss

    private var downloads: Downloads { model.downloads }
    private var pin: DownloadInventory.ArtistPin? {
        downloads.inventory.artists.first { $0.key == key }
    }

    var body: some View {
        List {
            if let pin {
                Section {
                    ForEach(pin.albums) { album in
                        albumLink(album)
                    }
                } footer: {
                    Text("Swipe an album away to keep the rest of \(pin.title).")
                }
                Section {
                    Button("Remove Download", role: .destructive) {
                        downloads.unpinArtist(pin.key)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .settingsBackground()
        .navigationTitle(pin?.title ?? "Artist")
        .navigationSubtitle(pin.map { DownloadText.bytes(bytes(of: $0.albums)) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // Narrowing the pin turns it into album pins, which live on the
        // list above; there is nothing left to show here.
        .onChange(of: pin == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func albumLink(_ album: PlexAlbum) -> some View {
        NavigationLink(value: DownloadRoute.album(album)) {
            DownloadRow(
                art: model.library?.artworkURL(album.thumb),
                round: false,
                title: album.title,
                subtitle: DownloadText.summary(
                    state: downloads.state(album),
                    bytes: downloads.inventory.statuses[album.ratingKey]?.bytes ?? 0,
                    unit: "track", count: album.leafCount ?? downloads.inventory.statuses[album.ratingKey]?.known
                ),
                detail: album.year.map(String.init)
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { downloads.unpin(album) } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func bytes(of albums: [PlexAlbum]) -> Int {
        albums.reduce(0) { $0 + (downloads.inventory.statuses[$1.ratingKey]?.bytes ?? 0) }
    }
}

/// An album's page in the manager: every track with its size, each one
/// removable on its own.
struct DownloadedAlbumPage: View {
    let model: AppModel
    let album: PlexAlbum
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [PlexTrack] = []

    private var downloads: Downloads { model.downloads }
    private var state: DownloadState { downloads.state(album) }

    var body: some View {
        List {
            Section {
                ForEach(tracks) { track in
                    DownloadedTrackRow(model: model, track: track, showAlbum: false)
                }
            } footer: {
                if case .complete(let count) = state, count > 0 {
                    Text("\(DownloadText.count(count, "track")) can't be downloaded.")
                } else if downloads.isPinned(album) {
                    Text("Swipe a track away to keep the rest of the album.")
                }
            }
            if downloads.isPinned(album) {
                Section {
                    Button("Remove Download", role: .destructive) {
                        downloads.unpin(album)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .settingsBackground()
        .navigationTitle(album.title)
        .navigationSubtitle(DownloadText.summary(
            state: state, bytes: downloads.inventory.statuses[album.ratingKey]?.bytes ?? 0,
            unit: "track", count: album.leafCount ?? downloads.inventory.statuses[album.ratingKey]?.known
        ))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: downloads.generation) {
            tracks = await downloads.tracks(inAlbum: album)
        }
    }
}

/// A track in the manager, with its size at the trailing edge, or what's
/// keeping it from having one.
private struct DownloadedTrackRow: View {
    let model: AppModel
    let track: PlexTrack
    let showAlbum: Bool

    private var downloads: Downloads { model.downloads }

    var body: some View {
        HStack(spacing: 12) {
            if showAlbum {
                Artwork(url: model.library?.artworkURL(track.thumb), size: 44, corner: 6)
            } else {
                Text(track.index.map(String.init) ?? "–")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if showAlbum {
                    Text("Track · " + [track.trackArtist ?? track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " — "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let artist = track.trackArtist {
                    Text(artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            if downloads.isPinned(track) {
                Button(role: .destructive) { downloads.unpin(track) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if downloads.isPinned(track) {
                Button(role: .destructive) { downloads.unpin(track) } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let bytes = downloads.bytes(track) {
            Text(DownloadText.bytes(bytes))
        } else if downloads.isDownloading(track) {
            if let server = downloads.server, downloads.inventory.isFailed(track, server: server) {
                Image(systemName: "exclamationmark.circle")
            } else {
                Image(systemName: "arrow.down.circle.dotted")
            }
        } else if track.part?.cacheKey == nil {
            Image(systemName: "nosign")
        } else {
            Text("—")
        }
    }
}

/// A section header with a line of explanation under it, the way iPhone
/// Storage captions its groups. The heading keeps the list's own header
/// styling; the detail is plain footnote text.
private struct SectionHeading: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

enum DeviceStorage {
    /// The name on the home screen.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tunes for Plex"
    }
}

/// Downloads, favorites kept downloaded and the play cache as one
/// segmented bar, whose whole is the downloads plus the cache's limit:
/// the unfilled tail is the room the cache has left before it trims.
private struct StorageBar: View {
    let downloads: Int
    let favorites: Int
    let cached: Int
    let cacheLimit: Int

    private var segments: [(Color, Double)] {
        let total = Double(max(downloads + favorites + max(cached, cacheLimit), 1))
        return [
            (.accentText, Double(downloads) / total),
            (.heart, Double(favorites) / total),
            (.artistMix, Double(cached) / total),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    // Anything on disk shows at least a sliver.
                    let width = segment.1 > 0 ? max(geometry.size.width * segment.1, 3) : 0
                    if width > 0 {
                        Rectangle().fill(segment.0).frame(width: width)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 22)
        .background(Color.ink.opacity(0.08))
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel("Storage: \(DownloadText.bytes(downloads)) of downloads, \(DownloadText.bytes(favorites)) of favorites, \(DownloadText.bytes(cached)) cached")
    }
}

/// An HStack that starts a new row when it runs out of width, for a
/// legend that has to hold two entries or three.
private struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map { $0.height }.reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private struct StorageLegend: View {
    let color: Color
    let label: String
    let bytes: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
            Text(DownloadText.bytes(bytes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Art, a title, and a line or two under it, for the artist and album
/// rows in the manager.
private struct DownloadRow: View {
    let art: URL?
    let round: Bool
    let title: String
    let subtitle: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: art, size: 44, corner: round ? 22 : 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text([detail, subtitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The manager's copy: byte counts and the state lines under each row.
/// Main actor for the formatter, which every caller is on anyway.
@MainActor
enum DownloadText {
    /// "0 KB" rather than the formatter's "Zero KB" for an empty root.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    static func count(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s")"
    }

    /// "12 tracks · 96 MB", "Downloading 3 of 12 · 24 MB", "Stalled at 3
    /// of 12", "4 of 12 tracks · 30 MB". `count` stands in for the total
    /// when the state has none, as with an artist row counting albums.
    static func summary(state: DownloadState, bytes: Int, unit: String, count: Int?) -> String {
        let size = Self.bytes(bytes)
        switch state {
        case .none:
            return count.map { "\(Self.count($0, unit)) · \(size)" } ?? size
        case .downloading(let done, let total, let stalled):
            return stalled ? "Stalled at \(done) of \(total) · \(size)" : "Downloading \(done) of \(total) · \(size)"
        case .partial(let done, let total):
            return "\(done) of \(total) tracks · \(size)"
        case .complete(let undownloadable):
            let total = count.map { Self.count($0, unit) } ?? "Downloaded"
            return undownloadable > 0 ? "\(total), \(undownloadable) can't download · \(size)" : "\(total) · \(size)"
        }
    }
}
