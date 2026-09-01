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
