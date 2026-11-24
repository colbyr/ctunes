import Foundation
@preconcurrency import MusicKit
import Observation
import PlexKit
import os

/// Apple Music beside the library (COL-117, `notes/apple-music.md`): what
/// the screens ask for songs and albums the library doesn't have. The
/// library is home; this only ever fills gaps, so everything it hands
/// back has had what the library owns taken out (`MusicMatch`), and comes
/// as the app's own `PlexTrack` and `PlexAlbum` with `am:` keys, which is
/// how every row, menu and the player know the source.
///
/// One per process, like the runtime: `Downloads.canPlay` and the engine
/// read it with no model in reach. Off until switched on in Settings.
@MainActor @Observable
final class AppleMusic {
    static let shared = AppleMusic()

    /// Whether Apple Music shows in search and on artist pages. Per
    /// device. A song already in the queue plays either way.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private static let enabledKey = "appleMusic.enabled"
    private(set) var authorization: MusicAuthorization.Status
    /// Whether the account can play the catalog; nil until asked.
    private(set) var canPlayCatalog: Bool?

    enum Status: Equatable {
        case off
        /// Never asked.
        case needsAccess
        /// Refused, or restricted: only the Settings app can change it.
        case denied
        /// Allowed, but no subscription that plays the catalog.
        case noSubscription
        case ready
    }

    var status: Status {
        guard isEnabled else { return .off }
        switch authorization {
        case .notDetermined: return .needsAccess
        case .denied, .restricted: return .denied
        case .authorized: return canPlayCatalog == false ? .noSubscription : .ready
        @unknown default: return .denied
        }
    }

    /// Whether search and the artist pages ask the catalog at all.
    var isBrowsable: Bool { Self.isSample || (isEnabled && authorization == .authorized) }
    /// Whether an Apple Music row can play: what `Downloads.canPlay`
    /// answers for one. Not gated on `isEnabled`, so a queue built before
    /// it was switched off still plays out.
    var canPlay: Bool { Self.isSample || (authorization == .authorized && canPlayCatalog != false) }

    @ObservationIgnored private var songs: [String: Song] = [:]
    @ObservationIgnored private var albumPages: [String: (album: PlexAlbum, tracks: [PlexTrack])] = [:]
    @ObservationIgnored private var artistShelves: [String: [PlexAlbum]] = [:]
    @ObservationIgnored private var urls: [String: URL] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "AppleMusic")

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        authorization = MusicAuthorization.currentStatus
        guard authorization == .authorized else { return }
        followSubscription()
    }

    // MARK: - Access

    /// Switches it on, asking for access the first time.
    func enable() async {
        isEnabled = true
        if authorization == .notDetermined {
            authorization = await MusicAuthorization.request()
        }
        if authorization == .authorized { followSubscription() }
    }

    /// Back from the Settings app, where access may have changed.
    func refresh() {
        authorization = MusicAuthorization.currentStatus
        if authorization == .authorized { followSubscription() }
    }

    @ObservationIgnored private var subscription: Task<Void, Never>?

    /// The subscription now and as it changes: lapsing mid-session dims
    /// the rows rather than failing each song as it loads.
    private func followSubscription() {
        guard subscription == nil else { return }
        subscription = Task { [weak self] in
            if let current = try? await MusicSubscription.current {
                self?.canPlayCatalog = current.canPlayCatalogContent
            }
            for await update in MusicSubscription.subscriptionUpdates {
                self?.canPlayCatalog = update.canPlayCatalogContent
            }
        }
    }

    // MARK: - Search

    struct SearchResults: Equatable {
        var albums: [PlexAlbum] = []
        var songs: [PlexTrack] = []
        var isEmpty: Bool { albums.isEmpty && songs.isEmpty }
    }

    /// The catalog's albums and songs for `term`, minus what the library
    /// has: a supplement to the library's results, so it is kept short.
    func search(_ term: String, owned: MusicMatch.Owned, artists: [PlexArtist]) async throws -> SearchResults {
        #if DEBUG
        if Self.isSample { return Sample.search(term, owned: owned, artists: artists) }
        #endif
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self])
        request.limit = 12
        let response = try await request.response()
        let albums = MusicMatch.uniqued(
            response.albums.filter { $0.isSingle != true && !owned.owns(album: $0.title, artist: $0.artistName) },
            by: { $0.artistName + "\u{1F}" + $0.title }
        )
        let songs = MusicMatch.uniqued(
            response.songs.filter { !owned.owns(song: $0.title, artist: $0.artistName, album: $0.albumTitle) },
            by: { $0.artistName + "\u{1F}" + $0.title }
        )
        return SearchResults(
            albums: albums.prefix(3).map { album($0, artists: artists) },
            songs: songs.prefix(5).map { track($0, artists: artists) }
        )
    }

    // MARK: - An artist's albums the library lacks

    /// The albums by a library artist that the library doesn't have,
    /// newest first: the artist page's shelf. Empty when the catalog has
    /// no artist of exactly that name; a near miss is not guessed at.
    /// Singles are left out: the shelf is for records.
    func albums(missingFor artist: ArtistRoute, owned libraryAlbums: [PlexAlbum]) async throws -> [PlexAlbum] {
        #if DEBUG
        if Self.isSample { return Sample.shelf(for: artist, owned: libraryAlbums) }
        #endif
        let name = MusicMatch.key(artist.title)
        var request = MusicCatalogSearchRequest(term: artist.title, types: [Artist.self])
        request.limit = 5
        guard let match = try await request.response().artists.first(where: { MusicMatch.key($0.name) == name }) else {
            log.notice("no catalog artist named \(artist.title, privacy: .public)")
            return []
        }
        var found: [Album] = []
        var batch = try await match.with([.albums]).albums
        var pages = 0
        while let current = batch, pages < 4 {
            found += current
            pages += 1
            batch = current.hasNextBatch ? try await current.nextBatch() : nil
        }
        let owned = MusicMatch.Owned(albums: libraryAlbums)
        let missing = found
            .filter { $0.isSingle != true && !owned.owns(albumTitled: $0.title) }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        let shelf = MusicMatch.uniqued(missing, by: \.title).map {
            album($0, artistKey: MusicMatch.key($0.artistName) == name ? artist.ratingKey : nil)
        }
        artistShelves[artist.ratingKey] = shelf
        log.notice("\(artist.title, privacy: .public): \(found.count) catalog albums, \(shelf.count) the library lacks")
        return shelf
    }

    /// The last shelf fetched for the artist, so a page opened again
    /// draws it on the first frame.
    func cachedShelf(for artistKey: String) -> [PlexAlbum]? { artistShelves[artistKey] }

    // MARK: - An album's page

    /// The album and its songs, for an album known only by its key (a
    /// recent search, a song's Go to Album). Songs carry the album's
    /// artist, with their own beside it where it differs.
    func page(for album: PlexAlbum, artists: [PlexArtist]) async throws -> (album: PlexAlbum, tracks: [PlexTrack]) {
        guard let id = album.appleMusicID else { throw CancellationError() }
        if let page = albumPages[id] { return page }
        #if DEBUG
        if Self.isSample { return Sample.page(for: album) }
        #endif
        var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id))
        request.properties = [.tracks]
        guard let found = try await request.response().items.first else {
            throw MusicKitFailure.notInCatalog
        }
        let full = self.album(found, artists: artists)
        let artwork = found.artwork?.url(width: 600, height: 600)
        let tracks: [PlexTrack] = (found.tracks ?? []).compactMap { entry in
            guard case .song(let song) = entry else { return nil }
            songs[song.id.rawValue] = song
            if let url = song.url { urls[AppleMusicID.songKey(song.id.rawValue)] = url }
            return PlexTrack.appleMusic(
                id: song.id.rawValue, title: song.title, artist: found.artistName,
                artistKey: full.parentRatingKey,
                credited: MusicMatch.key(song.artistName) == MusicMatch.key(found.artistName) ? nil : song.artistName,
                album: found.title, albumID: id,
                index: song.trackNumber, disc: song.discNumber, duration: song.duration,
                artwork: song.artwork?.url(width: 600, height: 600) ?? artwork
            )
        }
        let page = (full, tracks)
        albumPages[id] = page
        return page
    }

    /// The whole album a song is on, for playing it from that song; nil
    /// when the song doesn't name its album.
    func albumTracks(around track: PlexTrack, artists: [PlexArtist]) async -> [PlexTrack]? {
        guard let album = track.album, album.isAppleMusic else { return nil }
        return try? await page(for: album, artists: artists).tracks
    }

    // MARK: - Songs for the engine

    enum MusicKitFailure: Error { case notInCatalog }

    /// The `Song` behind a queue entry: the one a search or an album page
    /// already loaded, else asked of the catalog by id, which is what a
    /// queue restored at launch or a recent search needs.
    func song(for track: PlexTrack) async throws -> Song {
        guard let id = track.appleMusicID else { throw MusicKitFailure.notInCatalog }
        if let song = songs[id] { return song }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try await request.response().items.first else { throw MusicKitFailure.notInCatalog }
        songs[id] = song
        return song
    }

    /// Asks for the songs of upcoming entries ahead of their turn, so the
    /// handoff doesn't wait on the catalog as well as on `prepareToPlay`.
    func warm(_ tracks: [PlexTrack]) {
        let missing = tracks.filter { track in track.appleMusicID.map { songs[$0] == nil } ?? false }
        guard !missing.isEmpty, canPlay else { return }
        Task {
            for track in missing { _ = try? await song(for: track) }
        }
    }

    /// Where the Music app opens the song or album: the catalog's own
    /// link when it has been seen, else built from the id.
    func musicAppURL(for key: String) -> URL? {
        if let url = urls[key] { return url }
        if let id = AppleMusicID.song(in: key) { return URL(string: "https://music.apple.com/song/\(id)") }
        if let id = AppleMusicID.album(in: key) { return URL(string: "https://music.apple.com/album/\(id)") }
        return nil
    }

    // MARK: - Shapes

    func track(_ song: Song, artists: [PlexArtist]) -> PlexTrack {
        let key = AppleMusicID.songKey(song.id.rawValue)
        songs[song.id.rawValue] = song
        if let url = song.url { urls[key] = url }
        return PlexTrack.appleMusic(
            id: song.id.rawValue, title: song.title, artist: song.artistName,
            artistKey: MusicMatch.artistKey(for: song.artistName, in: artists),
            album: song.albumTitle, albumID: AppleMusicID.album(inSongURL: song.url),
            index: song.trackNumber, disc: song.discNumber, duration: song.duration,
            artwork: song.artwork?.url(width: 600, height: 600)
        )
    }

    private func album(_ album: Album, artists: [PlexArtist]) -> PlexAlbum {
        self.album(album, artistKey: MusicMatch.artistKey(for: album.artistName, in: artists))
    }

    private func album(_ album: Album, artistKey: String?) -> PlexAlbum {
        if let url = album.url { urls[AppleMusicID.albumKey(album.id.rawValue)] = url }
        return PlexAlbum.appleMusic(
            id: album.id.rawValue, title: album.title, artist: album.artistName, artistKey: artistKey,
            year: album.releaseDate.map { Calendar.current.component(.year, from: $0) },
            trackCount: album.trackCount,
            artwork: album.artwork?.url(width: 600, height: 600)
        )
    }
}

// MARK: - Sample catalog (Debug)

extension AppleMusic {
    /// `CTUNES_DEV_APPLE_MUSIC=sample` answers every catalog request from
    /// the made-up records below, so the screens can be looked at in a
    /// simulator, where MusicKit has no account and no player. Nothing
    /// plays: the engine fails each entry and the queue moves on.
    static var isSample: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_APPLE_MUSIC"] != nil
        #else
        false
        #endif
    }
}

#if DEBUG
extension AppleMusic {
    enum Sample {
        private static let titles = ["Paper Lanterns", "Night Ferry", "Small Hours", "Salt and Vinegar", "A Borrowed Coat"]
        private static let songs = ["Opening", "Harbour Lights", "Slow Train", "Kitchen Radio", "The Long Way",
                                    "Interlude", "Northbound", "Glass", "Last Orders", "Closing"]

        /// Albums "by" whatever was typed, so the artist key resolves
        /// when the query names a library artist, and one song the
        /// library can't have.
        static func search(_ term: String, owned: MusicMatch.Owned, artists: [PlexArtist]) -> SearchResults {
            let artist = artists.first { MusicMatch.key($0.title).hasPrefix(MusicMatch.key(term)) }
            let name = artist?.title ?? term.capitalized
            let albums = titles.prefix(2).enumerated().map { offset, title in
                PlexAlbum.appleMusic(id: "9\(abs(name.hashValue) % 10_000)\(offset)", title: title, artist: name,
                                     artistKey: artist?.ratingKey, year: 2019 + offset, trackCount: songs.count)
            }.filter { !owned.owns(album: $0.title, artist: name) }
            let tracks = songs.prefix(3).enumerated().map { offset, title in
                PlexTrack.appleMusic(id: "8\(abs(name.hashValue) % 10_000)\(offset)", title: title, artist: name,
                                     artistKey: artist?.ratingKey, album: albums.first?.title,
                                     albumID: albums.first?.appleMusicID, index: offset + 1, disc: 1,
                                     duration: 185 + Double(offset * 37))
            }
            return SearchResults(albums: Array(albums), songs: tracks)
        }

        static func shelf(for artist: ArtistRoute, owned: [PlexAlbum]) -> [PlexAlbum] {
            let have = MusicMatch.Owned(albums: owned)
            return titles.enumerated().map { offset, title in
                PlexAlbum.appleMusic(id: "7\(artist.ratingKey)\(offset)", title: title, artist: artist.title,
                                     artistKey: artist.ratingKey, year: 2023 - offset * 3, trackCount: songs.count)
            }.filter { !have.owns(albumTitled: $0.title) }
        }

        static func page(for album: PlexAlbum) -> (album: PlexAlbum, tracks: [PlexTrack]) {
            let id = album.appleMusicID ?? "0"
            let tracks = songs.enumerated().map { offset, title in
                PlexTrack.appleMusic(id: "\(id)\(offset)", title: title, artist: album.parentTitle ?? "",
                                     artistKey: album.parentRatingKey, album: album.title, albumID: id,
                                     index: offset + 1, disc: 1, duration: 170 + Double(offset * 23))
            }
            let full = PlexAlbum.appleMusic(id: id, title: album.title, artist: album.parentTitle ?? "",
                                            artistKey: album.parentRatingKey, year: album.year ?? 2021,
                                            trackCount: tracks.count)
            return (full, tracks)
        }
    }
}
#endif
