import AppIntents
import Foundation
import PlexKit

/// What an intent can say went wrong. Siri speaks the message, so each
/// is a sentence that makes sense out loud with no screen behind it.
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case connecting
    case unreachable
    case noSection
    case fetchFailed
    case noFavorites
    case nothingToPlay
    case nothingDownloaded
    case nothingToResume
    case noSuchPlaylist
    case noSuchItem

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Tunes first."
        case .connecting: "Tunes is still connecting to your Plex server. Try again in a moment."
        case .unreachable: "Tunes couldn't reach your Plex server."
        case .noSection: "Pick a music library in Tunes first."
        case .fetchFailed: "Tunes couldn't load that from your Plex server."
        case .noFavorites: "You haven't favorited anything yet."
        case .nothingToPlay: "There's nothing to play."
        case .nothingDownloaded: "Nothing there is downloaded, and the server can't be reached."
        case .nothingToResume: "There's nothing to resume."
        case .noSuchPlaylist: "Tunes couldn't find that playlist."
        case .noSuchItem: "Tunes couldn't find that in your library."
        }
    }
}

/// The play paths behind the App Shortcuts: the same fetches, vetoes and
/// shuffle as the screens and the car, without a window. An intent can
/// fire with the phone locked and `bootstrap` still running, so `ready()`
/// waits for launch to settle before handing back the runtime's model and
/// player. Everything here is a `LibraryActions` or `CarPlayController`
/// path, minus the presentation those own.
@MainActor
struct IntentPlayback {
    let model: AppModel
    let player: AudioPlayer
    let catalog: LibraryCatalog
    /// The library open when the intent started. Read through `library`,
    /// which prefers the model's: a fetch that fails may swap it in place.
    private let initialLibrary: any LibrarySource
    private let section: PlexSection

    /// How many albums "Play On Rotation" queues, front to back each.
    static let rotationAlbums = 10

    static func ready() async throws -> IntentPlayback {
        let runtime = AppRuntime.shared
        switch await runtime.model.ready() {
        case .signedOut, .linking: throw IntentFailure.signedOut
        case .connectFailed: throw IntentFailure.unreachable
        case .loading, .connecting: throw IntentFailure.connecting
        case .signedIn, .offline, .reconnecting: break
        }
        guard let library = runtime.model.library else { throw IntentFailure.connecting }
        guard let section = runtime.model.selectedSection else { throw IntentFailure.noSection }
        return IntentPlayback(
            model: runtime.model, player: runtime.player, catalog: runtime.catalog,
            initialLibrary: library, section: section
        )
    }

    private var library: any LibrarySource { model.library ?? initialLibrary }
    private var offline: Bool { library.isOffline }
    /// What the entity ids carry, so an id from another server never
    /// resolves (`SiriID`).
    var server: String { library.serverIdentifier }

    // MARK: - The shortcuts

    /// Every favorite minus what the active listeners veto, spread
    /// shuffled: the Favorites page's Shuffle card. Returns the count.
    func shuffleFavorites() async throws -> Int {
        let hearted = try await fetch { try await library.favoriteTracks(inSection: section.key) }
        if hearted.isEmpty, !offline { throw IntentFailure.noFavorites }
        let tracks = playable(hearted, within: nil).spreadShuffled()
        try play(tracks)
        return tracks.count
    }

    /// The top of On Rotation as whole albums in rotation order, the way
    /// the browse root ranks them. Returns the albums queued.
    func playOnRotation() async throws -> [PlexAlbum] {
        let top = Array(try await rotationAlbums().prefix(Self.rotationAlbums))
        let tracks = try await withThrowingTaskGroup(of: (Int, [PlexTrack]).self) { group in
            for (index, album) in top.enumerated() {
                group.addTask { (index, try await self.tracks(of: album)) }
            }
            var batches: [(Int, [PlexTrack])] = []
            for try await batch in group { batches.append(batch) }
            return batches.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        let queued = playable(tracks, within: .album)
        try play(queued)
        let keys = Set(queued.compactMap(\.parentRatingKey))
        return top.filter { keys.contains($0.ratingKey) }
    }

    /// A playlist front to back, or shuffled: the page's Play and Shuffle
    /// cards. Every veto applies, since a playlist is a mixed bag.
    /// Returns the count.
    func play(playlist: PlexPlaylist, shuffled: Bool) async throws -> Int {
        let items = try await fetch { try await library.items(inPlaylist: playlist.ratingKey) }
        await model.rememberItems(items, inPlaylist: playlist)
        let tracks = playable(items.map(\.track), within: nil)
        try play(shuffled ? tracks.spreadShuffled() : tracks)
        return tracks.count
    }

    /// Picks up where the queue left off. Returns the track playing.
    func resume() throws -> PlexTrack {
        guard let track = player.currentTrack else { throw IntentFailure.nothingToResume }
        player.resume()
        return player.currentTrack ?? track
    }

    // MARK: - The catalog

    /// The section as the browse root loads it, loaded here when no root
    /// has: with no window nothing else asks for it.
    private func loadCatalog() async throws {
        try await fetch { try await catalog.load(from: library, section: section) }
    }

    func artists() async throws -> [PlexArtist] {
        try await loadCatalog()
        return catalog.artists
    }

    func albums() async throws -> [PlexAlbum] {
        try await loadCatalog()
        return catalog.albums
    }

    /// Every album the active listeners can see in rotation order, the
    /// way the browse root ranks them: the play counts when there is no
    /// history.
    func rotationAlbums() async throws -> [PlexAlbum] {
        let albums = try await albums()
        let hidden = model.roster.hidden
        return AlbumView.mostPlayed.sorted(albums.filter { !hidden.hides($0) }, rotation: catalog.rotation)
    }

    func track(ratingKey: String) async throws -> PlexTrack? {
        try await fetch { try await library.track(ratingKey: ratingKey) }
    }

    // MARK: - Siri's search

    /// What "play X" can mean, best first: the search page's ranking over
    /// the catalog, the playlists and the server's track search, minus
    /// what the active listeners veto, at most `AudioSearchQuery.limit`
    /// of each kind. The track search is optional, as on the page: the
    /// artists and albums still answer when it fails.
    func search(_ query: String) async throws -> [AudioEntity] {
        try await loadCatalog()
        async let playlistList = playlists()
        let tracks = (try? await library.searchTracks(inSection: section.key, query: query)) ?? []
        let hits = LibrarySearch.hits(
            artists: catalog.artists, albums: catalog.albums, tracks: tracks,
            playlists: await playlistList, query: query, hiding: model.roster.hidden,
            trackLimit: AudioSearchQuery.limit
        )
        var counts: [Int: Int] = [:]
        return hits.compactMap { hit in
            let entity: AudioEntity
            let kind: Int
            switch hit {
            case .artist(let artist): (entity, kind) = (.artist(ArtistEntity(artist, server: server)), 0)
            case .album(let album): (entity, kind) = (.album(AlbumEntity(album, server: server)), 1)
            case .playlist(let playlist): (entity, kind) = (.playlist(PlaylistEntity(playlist, server: server)), 2)
            case .track(let track): (entity, kind) = (.song(SongEntity(track, server: server)), 3)
            }
            counts[kind, default: 0] += 1
            return counts[kind, default: 0] <= AudioSearchQuery.limit ? entity : nil
        }
    }

    // MARK: - Play an entity

    /// The queue the item's own page would play: an artist in release
    /// order minus their vetoed albums and tracks, an album minus the
    /// tracks vetoed on their own, a song's album from that song (the
    /// song itself always kept, as a search result plays), a playlist
    /// minus every veto since it is a mixed bag. `.shuffle` is the spread
    /// shuffle (a song stays first), `.repeat` repeats the queue;
    /// `.next` and `.tail` add to the queue instead of replacing it.
    /// Returns what the intent says.
    func play(_ entity: AudioEntity, attributes: Set<PlaybackAttribute>, location: QueueInsertionLocation?) async throws -> String {
        var tracks: [PlexTrack]
        var start = 0
        let name: String
        switch entity {
        case .artist(let artist):
            let all = try await fetch { try await library.tracks(forArtist: artist.ratingKey, inSection: section.key) }
            tracks = playable(all, within: .artist)
            name = artist.name
        case .album(let album):
            let all = try await fetch { try await library.tracks(inAlbum: album.ratingKey) }
            if let known = catalog.albums.first(where: { $0.ratingKey == album.ratingKey }) {
                await model.rememberTracks(all, inAlbum: known)
            }
            tracks = playable(all, within: .album)
            name = album.artistName.isEmpty ? album.title : "\(album.title) by \(album.artistName)"
        case .song(let song):
            guard let track = try await track(ratingKey: song.ratingKey) else { throw IntentFailure.noSuchItem }
            var siblings = [track]
            if let key = song.albumRatingKey, let fetched = try? await library.tracks(inAlbum: key), !fetched.isEmpty {
                siblings = fetched
                if let album = track.album { await model.rememberTracks(fetched, inAlbum: album) }
            }
            let rest = playable(siblings.filter { $0.id != track.id }, within: .album)
            tracks = siblings.filter { sibling in sibling.id == track.id || rest.contains { $0.id == sibling.id } }
            if !tracks.contains(where: { $0.id == track.id }) { tracks.insert(track, at: 0) }
            start = tracks.firstIndex { $0.id == track.id } ?? 0
            name = song.artistName.isEmpty ? song.title : "\(song.title) by \(song.artistName)"
        case .playlist(let playlist):
            let found = try await self.playlist(ratingKey: playlist.ratingKey)
            let items = try await fetch { try await library.items(inPlaylist: found.ratingKey) }
            await model.rememberItems(items, inPlaylist: found)
            tracks = playable(items.map(\.track), within: nil)
            name = found.title
        }
        if attributes.contains(.shuffle), !tracks.isEmpty {
            if case .song = entity {
                let first = tracks[start]
                tracks = [first] + tracks.filter { $0.id != first.id }.spreadShuffled()
            } else {
                tracks = tracks.spreadShuffled()
            }
            start = 0
        }
        guard !tracks.isEmpty else { throw offline ? IntentFailure.nothingDownloaded : IntentFailure.nothingToPlay }
        switch location {
        case .next:
            player.playNext(tracks, library: library)
            return "Playing \(name) next."
        case .tail:
            player.addToQueue(tracks, library: library)
            return "Added \(name) to the queue."
        case nil:
            player.play(tracks, startingAt: start, library: library)
            if attributes.contains(.repeat) { player.setRepeat(.all) }
            return attributes.contains(.shuffle) ? "Shuffling \(name)." : "Playing \(name)."
        }
    }

    // MARK: - Playlists

    /// The section's playlists, loaded here when no screen has: with no
    /// window nothing else asks for them. Offline they come with the
    /// snapshot.
    func playlists() async -> [PlexPlaylist] {
        if model.playlists.isEmpty { await model.loadPlaylists() }
        return model.playlists
    }

    func playlist(ratingKey: String) async throws -> PlexPlaylist {
        guard let playlist = await playlists().first(where: { $0.ratingKey == ratingKey }) else {
            throw IntentFailure.noSuchPlaylist
        }
        return playlist
    }

    // MARK: - Helpers

    /// One request, and on a connection error the same rediscovery a
    /// screen runs, retried once when the server answers elsewhere.
    private func fetch<T: Sendable>(_ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch {
            guard await model.connectionLost(error) else { throw IntentFailure.fetchFailed }
            do {
                return try await request()
            } catch {
                throw IntentFailure.fetchFailed
            }
        }
    }

    private func tracks(of album: PlexAlbum) async throws -> [PlexTrack] {
        let tracks = try await fetch { try await library.tracks(inAlbum: album.ratingKey) }
        await model.rememberTracks(tracks, inAlbum: album)
        return tracks
    }

    /// What can enter the queue: never a track the active listeners hide
    /// inside the collection, and offline only a track with a file.
    private func playable(_ tracks: [PlexTrack], within container: VetoKind?) -> [PlexTrack] {
        let hidden = model.roster.hidden
        return tracks.filter {
            !hidden.hides($0, within: container) && (!offline || model.downloads.isAvailable($0))
        }
    }

    private func play(_ tracks: [PlexTrack]) throws {
        guard !tracks.isEmpty else { throw offline ? IntentFailure.nothingDownloaded : IntentFailure.nothingToPlay }
        player.play(tracks, startingAt: 0, library: library)
    }
}
