import PlexKit
import SwiftUI

/// Where the manager's pages go on the Settings stack.
enum DownloadRoute: Hashable {
    case artist(key: String)
    case album(PlexAlbum)
}

/// The download manager, a page of Settings: what's kept offline, by
/// artist, album and track, how much each takes, and a way to remove any
/// of it. Reads the inventory mirror; every row is a pin as the store
/// holds it, so an album under an artist appears on the artist's page and
/// not here.
struct DownloadsList: View {
    let model: AppModel
    @State private var confirmingRemoveAll = false

    private var downloads: Downloads { model.downloads }
    private var inventory: DownloadInventory { downloads.inventory }
    private var offline: Bool { model.state == .offline }

    var body: some View {
        List {
            summarySection
            if !inventory.artists.isEmpty { artistsSection }
            if !inventory.albums.isEmpty { albumsSection }
            if !inventory.tracks.isEmpty { tracksSection }
            favoritesSection
            if !downloads.isEmpty { removeSection }
        }
        .parchment()
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if downloads.isEmpty {
                ContentUnavailableView(
                    "No downloads", systemImage: "arrow.down.circle",
                    description: Text("Long-press an artist, album or track and choose Download to keep it offline.")
                )
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("Everything kept offline will stream again. Nothing is removed from your library.")
        }
        .task { downloads.refresh() }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(DownloadText.bytes(downloads.usage))
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                Text(summaryLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
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

    private var summaryLine: String {
        let files = inventory.files.count
        var parts: [String] = []
        if !inventory.artists.isEmpty { parts.append(DownloadText.count(inventory.artists.count, "artist")) }
        if !inventory.albums.isEmpty { parts.append(DownloadText.count(inventory.albums.count, "album")) }
        if !inventory.tracks.isEmpty { parts.append(DownloadText.count(inventory.tracks.count, "track")) }
        if inventory.favoritesPinned { parts.append("favorites") }
        let pins = parts.isEmpty ? "Nothing kept offline" : parts.joined(separator: ", ")
        return "\(pins) · \(DownloadText.count(files, "file")) on this device"
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
            Text("Removes every download and turns off Keep Favorites Offline. Recently played tracks stay cached until they clear themselves.")
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
