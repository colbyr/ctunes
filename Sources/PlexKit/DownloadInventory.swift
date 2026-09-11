import Foundation

/// Everything the download manager and the art badges read, computed by
/// `OfflineStore.inventory(server:)` in one pass over the pinned root. A
/// value, so the app can mirror it onto the main actor and views can read
/// it without an await.
public struct DownloadInventory: Sendable, Equatable {
    /// A whole artist kept offline: every album they had when pinned.
    public struct ArtistPin: Sendable, Equatable, Identifiable {
        public let key: String
        public let title: String
        public let thumb: String?
        public let albums: [PlexAlbum]
        public let pinnedAt: Date
        public var id: String { key }

        public init(key: String, title: String, thumb: String?, albums: [PlexAlbum], pinnedAt: Date) {
            self.key = key
            self.title = title
            self.thumb = thumb
            self.albums = albums
            self.pinnedAt = pinnedAt
        }
    }

    /// An album pinned on its own, not through its artist.
    public struct AlbumPin: Sendable, Equatable, Identifiable {
        public let album: PlexAlbum
        public let pinnedAt: Date
        public var id: String { album.ratingKey }

        public init(album: PlexAlbum, pinnedAt: Date) {
            self.album = album
            self.pinnedAt = pinnedAt
        }
    }

    /// Artist pins, oldest first.
    public var artists: [ArtistPin] = []
    /// Album pins, oldest first. Disjoint from the artist pins: pinning an
    /// artist absorbs their album pins, and removing an album under an
    /// artist pin narrows the artist to their other albums.
    public var albums: [AlbumPin] = []
    /// Tracks pinned on their own, in pin order. Disjoint from the album
    /// and artist pins the same way.
    public var tracks: [PlexTrack] = []
    public var favoritesPinned = false
    /// The favorites group, whether or not the pin is on.
    public var favorites: [PlexTrack] = []
    /// By album ratingKey: every album with a saved track list, a file in
    /// the pinned root or a pin still coming down.
    public var statuses: [String: AlbumDownloadStatus] = [:]
    /// Bytes on disk in the pinned root, by cache path.
    public var files: [String: Int] = [:]
    /// Cache paths any pin wants, on disk or not.
    public var wanted: Set<String> = []
    /// Cache paths whose last fetch failed and are inside the backoff.
    public var failed: Set<String> = []
    /// Bytes of saved covers and portraits.
    public var artBytes = 0

    public init() {}

    /// Bytes of pinned audio and art.
    public var totalBytes: Int { files.values.reduce(0, +) + artBytes }

    /// Whether the file is in the pinned root right now.
    public func isDownloaded(_ track: PlexTrack, server: String) -> Bool {
        bytes(for: track, server: server) != nil
    }

    public func bytes(for track: PlexTrack, server: String) -> Int? {
        track.part?.cachePath(server: server).flatMap { files[$0] }
    }

    /// A pin wants it and the file isn't down yet.
    public func isDownloading(_ track: PlexTrack, server: String) -> Bool {
        guard let path = track.part?.cachePath(server: server) else { return false }
        return wanted.contains(path) && files[path] == nil
    }

    public func isFailed(_ track: PlexTrack, server: String) -> Bool {
        track.part?.cachePath(server: server).map(failed.contains) ?? false
    }

    public func isArtistPinned(_ key: String) -> Bool {
        artists.contains { $0.key == key }
    }

    /// Pinned on its own or through its artist.
    public func isAlbumPinned(_ key: String) -> Bool {
        statuses[key]?.pinned ?? false
    }

    /// Wanted by an artist, album or track pin; not by the favorites pin
    /// alone, which comes and goes with the heart.
    public func isTrackPinned(_ track: PlexTrack) -> Bool {
        if tracks.contains(where: { $0.ratingKey == track.ratingKey }) { return true }
        guard let album = track.parentRatingKey else { return false }
        return isAlbumPinned(album)
    }

    /// Bytes on disk and the file count for a list of tracks.
    public func usage(of tracks: [PlexTrack], server: String) -> (bytes: Int, files: Int) {
        var bytes = 0, count = 0
        for track in tracks {
            if let size = self.bytes(for: track, server: server) {
                bytes += size
                count += 1
            }
        }
        return (bytes, count)
    }

    /// The state of an album's download, from what's on disk and what any
    /// pin still wants. `album.leafCount` fills in the track count when the
    /// album was never browsed, so two pinned tracks of twelve read as
    /// partial rather than complete.
    public func state(of album: PlexAlbum) -> DownloadState {
        DownloadState(statuses[album.ratingKey]?.rollup(trackCount: album.leafCount) ?? .init())
    }

    /// The artist's albums rolled up: the section's list for the totals,
    /// plus any album with files the list doesn't have.
    public func state(ofArtist key: String, albums: [PlexAlbum]) -> DownloadState {
        var rollup = DownloadState.Rollup()
        var seen: Set<String> = []
        for album in albums where album.parentRatingKey == key {
            seen.insert(album.ratingKey)
            rollup += statuses[album.ratingKey]?.rollup(trackCount: album.leafCount)
                ?? .init(total: album.leafCount ?? 0)
        }
        for (albumKey, status) in statuses where status.artistKey == key && !seen.contains(albumKey) {
            rollup += status.rollup(trackCount: nil)
        }
        return DownloadState(rollup)
    }
}

/// What the pinned root holds for one album.
public struct AlbumDownloadStatus: Sendable, Equatable {
    public var artistKey: String?
    /// Tracks with a file in the pinned root.
    public var done = 0
    /// Tracks in the saved list; zero when the album is known only through
    /// pinned tracks or favorites.
    public var known = 0
    /// Fetchable tracks a pin wants that have no file yet.
    public var missing = 0
    /// Of `missing`, those whose last fetch failed and is inside the backoff.
    public var failed = 0
    /// Wanted tracks with no cache key, which never download.
    public var undownloadable = 0
    public var bytes = 0
    /// An album pin, or an artist pin covering it.
    public var pinned = false

    public init(artistKey: String? = nil, done: Int = 0, known: Int = 0, missing: Int = 0,
                failed: Int = 0, undownloadable: Int = 0, bytes: Int = 0, pinned: Bool = false) {
        self.artistKey = artistKey
        self.done = done
        self.known = known
        self.missing = missing
        self.failed = failed
        self.undownloadable = undownloadable
        self.bytes = bytes
        self.pinned = pinned
    }

    func rollup(trackCount: Int?) -> DownloadState.Rollup {
        .init(
            done: done,
            total: max(known, trackCount ?? 0, done + missing + undownloadable),
            missing: missing,
            failed: failed,
            undownloadable: undownloadable
        )
    }
}

/// An album's or artist's download, as the badge on its art shows it.
public enum DownloadState: Sendable, Equatable {
    case none
    /// A pin is still coming down. `stalled` when every missing file's
    /// last fetch failed and is waiting out the backoff.
    case downloading(done: Int, total: Int, stalled: Bool)
    /// Some files are down and nothing is on its way: a few tracks pinned,
    /// or an album pin removed from an artist pin.
    case partial(done: Int, total: Int)
    /// Every track is down but for `undownloadable`, which have no file
    /// the cache can fetch.
    case complete(undownloadable: Int)

    /// Counts summed across albums, so an artist rolls up the same way.
    public struct Rollup: Sendable, Equatable {
        public var done = 0
        public var total = 0
        public var missing = 0
        public var failed = 0
        public var undownloadable = 0

        public init(done: Int = 0, total: Int = 0, missing: Int = 0, failed: Int = 0, undownloadable: Int = 0) {
            self.done = done
            self.total = total
            self.missing = missing
            self.failed = failed
            self.undownloadable = undownloadable
        }

        public static func += (lhs: inout Rollup, rhs: Rollup) {
            lhs.done += rhs.done
            lhs.total += rhs.total
            lhs.missing += rhs.missing
            lhs.failed += rhs.failed
            lhs.undownloadable += rhs.undownloadable
        }
    }

    public init(_ rollup: Rollup) {
        if rollup.missing > 0 {
            self = .downloading(done: rollup.done, total: rollup.total, stalled: rollup.failed >= rollup.missing)
        } else if rollup.done == 0 {
            self = .none
        } else if rollup.done + rollup.undownloadable >= rollup.total {
            self = .complete(undownloadable: rollup.undownloadable)
        } else {
            self = .partial(done: rollup.done, total: rollup.total)
        }
    }

    /// Something on disk: a badge to draw.
    public var hasFiles: Bool {
        switch self {
        case .none: false
        case .downloading(let done, _, _): done > 0
        case .partial, .complete: true
        }
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var isStalled: Bool {
        if case .downloading(_, _, true) = self { return true }
        return false
    }

    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}
