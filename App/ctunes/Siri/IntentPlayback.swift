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
        return IntentPlayback(model: runtime.model, player: runtime.player, initialLibrary: library, section: section)
    }

    private var library: any LibrarySource { model.library ?? initialLibrary }
    private var offline: Bool { library.isOffline }

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
        let albums = try await fetch { try await library.albums(inSection: section.key) }
        // Optional, as on the root: without it the sort is the play counts.
        let history = (try? await library.playHistory(inSection: section.key, since: .now - Rotation.window)) ?? []
        let rotation = Rotation(history: history, albums: albums)
        let hidden = model.roster.hidden
        let ranked = AlbumView.mostPlayed.sorted(albums.filter { !hidden.hides($0) }, rotation: rotation)
        let top = Array(ranked.prefix(Self.rotationAlbums))
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
