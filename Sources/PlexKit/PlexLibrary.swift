import Foundation

/// Reads a server's music libraries.
public actor PlexLibrary {
    private let client: PlexClient
    private let server: PlexServer
    private let token: String

    public init(client: PlexClient, server: PlexServer, token: String) {
        self.client = client
        self.server = server
        self.token = token
    }

    public nonisolated var baseURL: URL { server.baseURL }

    private func fetch<Item: Decodable & Sendable>(
        _ type: Item.Type,
        path: String
    ) async throws -> [Item] {
        guard let url = URL(string: server.baseURL.absoluteString + path) else {
            throw PlexError.noServerReachable
        }
        let response = try await client.get(
            MediaContainerResponse<Item>.self, url: url, token: token
        )
        return response.items
    }

    public func musicSections() async throws -> [PlexSection] {
        try await fetch(PlexSection.self, path: "/library/sections")
            .filter(\.isMusic)
    }

    public func artists(inSection section: String) async throws -> [PlexArtist] {
        try await fetch(PlexArtist.self, path: "/library/sections/\(section)/all?type=8")
    }

    /// Every album in the library, in the server's own order (artist, then
    /// album). The browse list groups these by artist rather than making one
    /// request per artist, which would be a request per row.
    public func albums(inSection section: String) async throws -> [PlexAlbum] {
        try await fetch(PlexAlbum.self, path: "/library/sections/\(section)/all?type=9")
    }

    /// Albums for one artist.
    ///
    /// Deliberately not `/library/metadata/{id}/children`: measured against a
    /// real library, that endpoint under-reports for 8 of 54 artists, in one
    /// case returning 8 albums where 13 exist. The filtered section query is
    /// correct for every artist checked.
    public func albums(
        forArtist artistRatingKey: String,
        inSection section: String
    ) async throws -> [PlexAlbum] {
        try await fetch(
            PlexAlbum.self,
            path: "/library/sections/\(section)/all?type=9&artist.id=\(artistRatingKey)"
        )
    }

    public func tracks(inAlbum albumRatingKey: String) async throws -> [PlexTrack] {
        try await fetch(PlexTrack.self, path: "/library/metadata/\(albumRatingKey)/children")
    }

    // MARK: - Ratings

    /// Every track rated a full 10 in the section.
    ///
    /// Exact match, not `>>=`: measured against a real server, `userRating=10`
    /// returns every favorite track while `userRating>>=10` returns nothing.
    public func favoriteTracks(inSection section: String) async throws -> [PlexTrack] {
        try await fetch(
            PlexTrack.self,
            path: "/library/sections/\(section)/all?type=10&userRating=10"
        )
    }

    /// Sets the rating to 10, or clears it. `rating=-1` is how Plex unrates.
    public func setFavorite(_ ratingKey: String, _ favorite: Bool) async throws {
        let rating = favorite ? 10 : -1
        guard let url = URL(string:
            server.baseURL.absoluteString
            + "/:/rate?identifier=com.plexapp.plugins.library"
            + "&key=\(ratingKey)&rating=\(rating)")
        else { throw PlexError.noServerReachable }
        let request = await client.request("PUT", url: url, token: token)
        try await client.data(for: request)
    }

    // MARK: - Timeline

    /// Tells the server where playback stands. This is the only way a play
    /// gets counted: the server marks the track played once progress reports
    /// cross ~90%, so `.playing` has to be sent periodically, not just once.
    /// `sessionIdentifier` groups the reports for one listening session.
    public func reportTimeline(
        _ track: PlexTrack,
        state: PlaybackState,
        time: Double,
        sessionIdentifier: String
    ) async throws {
        var components = URLComponents(
            url: server.baseURL.appending(path: "/:/timeline"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "ratingKey", value: track.ratingKey),
            .init(name: "key", value: "/library/metadata/\(track.ratingKey)"),
            .init(name: "state", value: state.rawValue),
            .init(name: "time", value: String(Int(time * 1000))),
            .init(name: "duration", value: String(track.duration ?? 0)),
            .init(name: "playbackTime", value: String(Int(time * 1000))),
            .init(name: "hasMDE", value: "1"),
        ]
        guard let url = components?.url else { throw PlexError.noServerReachable }
        var request = await client.request(url: url, token: token)
        request.setValue(sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")
        try await client.data(for: request)
    }

    // MARK: - URLs

    /// The audio file itself. AVPlayer won't attach custom headers to media
    /// requests, so the token has to ride in the query string here.
    public nonisolated func streamURL(for track: PlexTrack) -> URL? {
        guard let part = track.part else { return nil }
        return URL(string: server.baseURL.absoluteString + part.key + "?X-Plex-Token=\(token)")
    }

    /// Artwork resized by the server, so list cells don't pull full-size covers.
    public nonisolated func artworkURL(_ thumb: String?, size: Int = 200) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        let encoded = thumb.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))
        ) ?? thumb
        return URL(string:
            server.baseURL.absoluteString
            + "/photo/:/transcode?width=\(size)&height=\(size)&minSize=1"
            + "&url=\(encoded)&X-Plex-Token=\(token)")
    }
}

/// The `state` values the timeline endpoint accepts.
public enum PlaybackState: String, Sendable {
    case playing, paused, stopped
}
