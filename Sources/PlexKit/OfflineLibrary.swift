import Foundation

/// A `LibrarySource` over a saved snapshot and the offline store, for when
/// the server can't be reached. Browsing works across the whole library;
/// tracks exist only for pinned albums and the favorites group, and writes
/// are refused.
public struct OfflineLibrary: LibrarySource {
    public let snapshot: LibrarySnapshot
    private let store: OfflineStore
    /// Kept in memory only, for artwork URLs; never written with the snapshot.
    private let token: String?

    public init(snapshot: LibrarySnapshot, store: OfflineStore, token: String? = nil) {
        self.snapshot = snapshot
        self.store = store
        self.token = token
    }

    public var serverIdentifier: String { snapshot.server }
    public var isOffline: Bool { true }

    public func musicSections() async throws -> [PlexSection] { snapshot.sections }

    public func artists(inSection section: String) async throws -> [PlexArtist] { snapshot.artists }

    public func albums(inSection section: String) async throws -> [PlexAlbum] { snapshot.albums }

    public func albums(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexAlbum] {
        snapshot.albums.filter { $0.parentRatingKey == artistRatingKey }
    }

    public func tracks(inAlbum albumRatingKey: String) async throws -> [PlexTrack] {
        await store.tracks(inAlbum: albumRatingKey, server: snapshot.server) ?? []
    }

    /// Pinned albums' tracks plus favorites by the artist, each track once.
    public func tracks(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexTrack] {
        var seen: Set<String> = []
        return await store.pinnedTracks(server: snapshot.server).filter {
            $0.grandparentRatingKey == artistRatingKey && seen.insert($0.ratingKey).inserted
        }
    }

    public func favoriteTracks(inSection section: String) async throws -> [PlexTrack] { snapshot.favorites }

    public func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws {
        throw PlexError.offline
    }

    public func reportTimeline(_ track: PlexTrack, state: PlaybackState, time: Double, sessionIdentifier: String) async throws {}

    /// Nothing to stream from; the player resolves by server and part.
    public func streamURL(for track: PlexTrack) -> URL? { nil }

    public func trackSource(for track: PlexTrack) -> TrackSource? { nil }

    /// The stored cover for a pinned album, whatever size was asked for;
    /// otherwise the server URL the image loader saw online, which its
    /// disk cache can still answer for anything scrolled past.
    public func artworkURL(_ thumb: String?, size: Int) -> URL? {
        if let saved = store.artURL(thumb, server: snapshot.server) { return saved }
        guard let base = snapshot.baseURL, let token else { return nil }
        return PlexLibrary.artworkURL(thumb, size: size, base: base, token: token)
    }
}
