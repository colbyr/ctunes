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
    @State private var device = DeviceStorage.read()

    private var downloads: Downloads { model.downloads }
    private var inventory: DownloadInventory { downloads.inventory }
    private var offline: Bool { model.state == .offline }

    var body: some View {
        List {
            overviewSection
            favoritesSection
            if !inventory.artists.isEmpty { artistsSection }
            if !inventory.albums.isEmpty { albumsSection }
            if !inventory.tracks.isEmpty { tracksSection }
            if downloads.isEmpty { emptySection } else { removeSection }
            cacheSection
        }
        .parchment()
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
            device = DeviceStorage.read()
        }
    }

    // MARK: - Sections

    /// The bar iPhone Storage draws: the app's two stores against what
    /// else is on the phone and what's free.
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                StorageBar(downloads: downloads.usage, cached: cacheUsage ?? 0, device: device)
                HStack(spacing: 14) {
                    StorageLegend(color: .accentText, label: "Downloads", bytes: downloads.usage)
                    StorageLegend(color: .artistMix, label: "Cached", bytes: cacheUsage ?? 0)
                }
                if let device {
                    Text("\(DownloadText.bytes(device.free)) free of \(DownloadText.bytes(device.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            } else {
                Text(summaryLine)
            }
        }
    }

    private var summaryLine: String {
        let files = inventory.files.count
        var parts: [String] = []
        if !inventory.artists.isEmpty { parts.append(DownloadText.count(inventory.artists.count, "artist")) }
        if !inventory.albums.isEmpty { parts.append(DownloadText.count(inventory.albums.count, "album")) }
        if !inventory.tracks.isEmpty { parts.append(DownloadText.count(inventory.tracks.count, "track")) }
        if inventory.favoritesPinned { parts.append("favorites") }
        let pins = parts.isEmpty ? "Nothing kept offline" : parts.joined(separator: ", ")
        return "\(pins) · \(DownloadText.count(files, "file")) downloaded"
    }

    private var emptySection: some View {
        Section("Downloads") {
            Text("Long-press an artist, album or track and choose Download to keep it offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var cacheSection: some View {
        Section {
            LabeledContent("Cached Tracks", value: DownloadText.bytes(cacheUsage ?? 0))
            Picker("Cache Size", selection: Binding(
                get: { player.cacheLimit },
                set: { player.cacheLimit = $0 }
            )) {
                ForEach(AudioPlayer.cacheLimitOptions, id: \.self) { bytes in
                    Text(DownloadText.bytes(bytes)).tag(bytes)
                }
            }
            if let cacheUsage, cacheUsage > 0 {
                Button("Clear Cached Tracks") {
                    Task {
                        await player.clearCache()
                        self.cacheUsage = await player.cacheUsage()
                    }
                }
            }
        } header: {
            Text("Play Cache")
        } footer: {
            Text("Recently played and upcoming tracks are kept so they don't stream twice, and clear themselves at the cache size. Downloads never count against it.")
        }
    }

    /// Any pin waiting out the backoff, so the retry line shows once.
    private var stalled: Bool {
        !inventory.failed.isEmpty
    }

    private var artistsSection: some View {
        Section("Artists") {
            ForEach(inventory.artists) { pin in
                NavigationLink(value: DownloadRoute.artist(key: pin.key)) {
                    DownloadRow(
                        art: model.library?.artworkURL(pin.thumb ?? pin.albums.first?.thumb),
                        round: true,
                        title: pin.title,
                        subtitle: DownloadText.summary(
                            state: downloads.state(artist: pin.key),
                            bytes: bytes(of: pin.albums),
                            unit: "album", count: pin.albums.count
                        )
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { downloads.unpinArtist(pin.key) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { downloads.unpinArtist(pin.key) } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var albumsSection: some View {
        Section("Albums") {
            ForEach(inventory.albums) { pin in
                albumLink(pin.album)
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
                detail: album.parentTitle
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { downloads.unpin(album) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) { downloads.unpin(album) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private var tracksSection: some View {
        Section("Tracks") {
            ForEach(inventory.tracks) { track in
                DownloadedTrackRow(model: model, track: track, showAlbum: true)
            }
        }
    }

    private var favoritesSection: some View {
        Section {
            Toggle("Keep Favorites Offline", isOn: Binding(
                get: { model.isFavoritesPinned },
                set: { on in Task { await model.setFavoritesPinned(on) } }
            ))
            .disabled(offline)
            if inventory.favoritesPinned {
                let usage = downloads.usage(of: inventory.favorites)
                LabeledContent("Favorites", value: "\(usage.files) of \(DownloadText.count(inventory.favorites.count, "track")) · \(DownloadText.bytes(usage.bytes))")
            }
        } footer: {
            Text("Favorites follow your hearts: a new favorite downloads, an unhearted one is removed. A favorite that is also in a downloaded album stays either way.")
        }
    }

    private var removeSection: some View {
        Section {
            Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                .foregroundStyle(.red)
        } footer: {
            Text("Removes every download and turns off Keep Favorites Offline. The play cache is left alone.")
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
        .parchment()
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
        .parchment()
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
                    Text([track.trackArtist ?? track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " — "))
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

/// What the phone reports for the volume the app lives on.
struct DeviceStorage: Equatable {
    let total: Int
    let free: Int

    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// space: it counts purgeable content the system would clear for the
    /// user, which is the figure iPhone Storage shows.
    static func read() -> DeviceStorage? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return DeviceStorage(total: total, free: Int(values.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

/// Downloads, the play cache, everything else on the phone, and free
/// space, as one segmented bar. With no device figures the app's two
/// stores share the bar between them.
private struct StorageBar: View {
    let downloads: Int
    let cached: Int
    let device: DeviceStorage?

    private var segments: [(Color, Double)] {
        let total = Double(device?.total ?? max(downloads + cached, 1))
        let free = Double(device?.free ?? 0)
        let other = max(total - free - Double(downloads) - Double(cached), 0)
        return [
            (.accentText, Double(downloads) / total),
            (.artistMix, Double(cached) / total),
            (Color.ink.opacity(0.25), other / total),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    // Anything the app holds shows at least a sliver, so a
                    // few MB on a 512 GB phone isn't invisible.
                    let width = segment.1 > 0 ? max(geometry.size.width * segment.1, 3) : 0
                    if width > 0 {
                        Rectangle().fill(segment.0).frame(width: width)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(Color.ink.opacity(0.08))
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityLabel("Storage: \(DownloadText.bytes(downloads)) of downloads, \(DownloadText.bytes(cached)) cached")
    }
}

private struct StorageLegend: View {
    let color: Color
    let label: String
    let bytes: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(DownloadText.bytes(bytes))")
                .font(.caption)
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
