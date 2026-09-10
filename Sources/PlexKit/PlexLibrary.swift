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
    public nonisolated var serverIdentifier: String { server.machineIdentifier }

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
    ///
    /// `/albums` rather than `all?type=9`: the same albums with the same
    /// fields, measured against a real library, plus `leafCount`, which
    /// On Rotation divides by.
    public func albums(inSection section: String) async throws -> [PlexAlbum] {
        try await fetch(PlexAlbum.self, path: "/library/sections/\(section)/albums")
    }

    /// The section's track plays since `since`, newest first. One request
    /// for the whole range: a year of plays is a few megabytes and well
    /// under a second on a LAN, and paging would be a request per screen.
    /// `>=` reaches the server as `%3E=`, which it accepts; `%3E%3D` is a 400.
    public func playHistory(inSection section: String, since: Date) async throws -> [PlayHistoryEntry] {
        let stamp = Int(since.timeIntervalSince1970)
        return try await fetch(
            PlayHistoryEntry.self,
            path: "/status/sessions/history/all?librarySectionID=\(section)&viewedAt>=\(stamp)&sort=viewedAt:desc"
        )
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

    /// Every track by one artist, for artist mixes. Section-filtered for the
    /// same reason as `albums(forArtist:)`: walking `/children` twice would
    /// inherit its under-reporting.
    public func tracks(
        forArtist artistRatingKey: String,
        inSection section: String
    ) async throws -> [PlexTrack] {
        try await fetch(
            PlexTrack.self,
            path: "/library/sections/\(section)/all?type=10&artist.id=\(artistRatingKey)"
        )
    }

    /// The whole section in one request: a mix of everything would
    /// otherwise be a request per artist.
    public func tracks(inSection section: String) async throws -> [PlexTrack] {
        try await fetch(PlexTrack.self, path: "/library/sections/\(section)/all?type=10")
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
        let request = client.request("PUT", url: url, token: token)
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
        var request = client.request(url: url, token: token)
        request.setValue(sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")
        try await client.data(for: request)
    }

    // MARK: - URLs

    /// The audio file itself, or the transcoder's HLS playlist for it.
    /// AVPlayer won't attach custom headers to media requests, so the token
    /// has to ride in the query string here.
    ///
    /// The transcoder, measured against a real server:
    /// - `start.m3u8` is a 400 for an iOS client unless
    ///   `X-Plex-Client-Profile-Extra` adds a music transcode target; the
    ///   built-in profile has none. The whole identity rides the query
    ///   since AVPlayer sends no headers.
    /// - The master points at `session/{id}/base/index.m3u8`, a relative
    ///   path AVPlayer resolves itself. That playlist and its `.ts` segments
    ///   need no token: the session id is the credential. It lists every
    ///   1s segment up front with `#EXT-X-ENDLIST`, so the duration is
    ///   finite and seeks are ordinary.
    /// - `musicBitrate` is honoured; a bitrate limitation in the profile
    ///   extra also works and wins when both are given.
    /// - A new start under the same `session` replaces the previous
    ///   transcode, so track changes need no `stop` call.
    /// - The server reuses a finished transcode of the same track for a few
    ///   minutes, at whatever bitrate it was first asked for.
    public nonisolated func streamURL(
        for track: PlexTrack,
        quality: StreamQuality,
        sessionIdentifier: String
    ) -> URL? {
        guard let part = track.part else { return nil }
        guard let bitrate = quality.bitrate else {
            return URL(string: server.baseURL.absoluteString + part.key + "?X-Plex-Token=\(token)")
        }
        let items: [URLQueryItem] = [
            .init(name: "path", value: "/library/metadata/\(track.ratingKey)"),
            .init(name: "mediaIndex", value: "0"),
            .init(name: "partIndex", value: "0"),
            .init(name: "protocol", value: "hls"),
            .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "0"),
            // Without this a segment beyond what has been cut takes ~2.2s
            // while the transcoder restarts at the offset, and AVFoundation
            // drops the only variant after 1s ("No response for media file
            // in 1s", -12880) and stalls for good. With it the same segment
            // arrives in ~0.2s, so seeks and the near-end dev hook work.
            .init(name: "fastSeek", value: "1"),
            .init(name: "musicBitrate", value: String(bitrate)),
            .init(name: "session", value: sessionIdentifier),
            // The server keys its streaming session by this, and without it
            // borrows the last one seen in a timeline report. The `stopped`
            // report for the previous track then lands after the new start
            // and terminates the new transcode: every segment 200s with an
            // empty body. Its own identifier keeps the two apart.
            .init(name: "X-Plex-Session-Identifier", value: sessionIdentifier),
            .init(
                name: "X-Plex-Client-Profile-Extra",
                value: "add-transcode-target(type=musicProfile&context=streaming"
                    + "&protocol=hls&container=mpegts&audioCodec=aac)"
            ),
            .init(name: "X-Plex-Token", value: token),
        ] + client.identity.queryItems
        // Strict encoding: the profile extra carries `&` and `=` that
        // `URLComponents` would leave bare and the server would split on.
        let query = items.map { "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))" }
            .joined(separator: "&")
        return URL(string: server.baseURL.absoluteString + "/music/:/transcode/universal/start.m3u8?" + query)
    }

    private nonisolated static func encode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))
        ) ?? value
    }

    /// The same file for the track cache to download. Unlike `streamURL`
    /// this can carry the token and identity headers, so it does.
    public nonisolated func trackSource(for track: PlexTrack) -> TrackSource? {
        guard let part = track.part, part.cacheKey != nil,
              let url = URL(string: server.baseURL.absoluteString + part.key)
        else { return nil }
        return TrackSource(
            server: server.machineIdentifier,
            part: part,
            request: client.request(url: url, token: token)
        )
    }

    /// Artwork resized by the server, so list cells don't pull full-size covers.
    public nonisolated func artworkURL(_ thumb: String?, size: Int = 400) -> URL? {
        Self.artworkURL(thumb, size: size, base: server.baseURL, token: token)
    }

    /// The same URL for an offline library, so the image cache is asked
    /// for exactly what it saw online.
    public static func artworkURL(_ thumb: String?, size: Int, base: URL, token: String) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        let encoded = thumb.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))
        ) ?? thumb
        return URL(string:
            base.absoluteString
            + "/photo/:/transcode?width=\(size)&height=\(size)&minSize=1"
            + "&url=\(encoded)&X-Plex-Token=\(token)")
    }
}

/// The `state` values the timeline endpoint accepts.
public enum PlaybackState: String, Sendable {
    case playing, paused, stopped
}
