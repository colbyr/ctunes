import Foundation

/// What the browse screens and the player need from a library, satisfied by
/// `PlexLibrary` against a server and by `OfflineLibrary` over a snapshot.
/// Views hold `any LibrarySource`, so entering and leaving offline swaps the
/// value behind one property instead of branching at every fetch.
public protocol LibrarySource: Sendable {
    var serverIdentifier: String { get }
    var isOffline: Bool { get }
    func musicSections() async throws -> [PlexSection]
    func artists(inSection section: String) async throws -> [PlexArtist]
    func albums(inSection section: String) async throws -> [PlexAlbum]
    func albums(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexAlbum]
    func tracks(inAlbum albumRatingKey: String) async throws -> [PlexTrack]
    func tracks(forArtist artistRatingKey: String, inSection section: String) async throws -> [PlexTrack]
    /// Every track in the section, for a mix with nothing picked.
    func tracks(inSection section: String) async throws -> [PlexTrack]
    func favoriteTracks(inSection section: String) async throws -> [PlexTrack]
    func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws
    func reportTimeline(_ track: PlexTrack, state: PlaybackState, time: Double, sessionIdentifier: String) async throws
    /// Synchronous: the player picks an item URL without hopping actors.
    func streamURL(for track: PlexTrack) -> URL?
    func trackSource(for track: PlexTrack) -> TrackSource?
    func artworkURL(_ thumb: String?, size: Int) -> URL?
}

extension LibrarySource {
    /// List-cell size, the default every grid uses.
    public func artworkURL(_ thumb: String?) -> URL? {
        artworkURL(thumb, size: 200)
    }
}

extension PlexLibrary: LibrarySource {
    public nonisolated var isOffline: Bool { false }
}
