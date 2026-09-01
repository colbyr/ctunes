import Foundation
import Testing
@testable import PlexKit

/// Exercises the real plex.tv API and a real server.
///
/// Disabled unless PLEX_LIVE is set and scripts/plex-dev-login.py has written
/// a token, so the normal suite stays hermetic and offline.
@Suite(
    "Live server",
    .enabled(if: ProcessInfo.processInfo.environment["PLEX_LIVE"] != nil)
)
struct LiveServerTests {
    struct DevCredentials: Decodable {
        let clientIdentifier: String
        let token: String
    }

    static func credentials() throws -> DevCredentials {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PlexKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".plex-dev.json")
        return try JSONDecoder().decode(DevCredentials.self, from: Data(contentsOf: url))
    }

    @Test("discovers and reaches a real server")
    func discoversRealServer() async throws {
        let credentials = try Self.credentials()
        let client = PlexClient(
            identity: PlexIdentity(clientIdentifier: credentials.clientIdentifier, product: "ctunes-dev")
        )
        let directory = PlexServerDirectory(client: client)

        let server = try await directory.selectServer(token: credentials.token)
        #expect(!server.machineIdentifier.isEmpty)
        #expect(server.baseURL.scheme == "https")
        print("→ reached \(server.name) at \(server.baseURL.absoluteString) (local: \(server.isLocal))")
    }

    @Test("walks a real library from sections down to a stream URL")
    func walksRealLibrary() async throws {
        let credentials = try Self.credentials()
        let client = PlexClient(
            identity: PlexIdentity(clientIdentifier: credentials.clientIdentifier, product: "ctunes-dev")
        )
        let server = try await PlexServerDirectory(client: client)
            .selectServer(token: credentials.token)
        let library = PlexLibrary(client: client, server: server, token: credentials.token)

        let sections = try await library.musicSections()
        #expect(!sections.isEmpty)
        print("→ sections: \(sections.map(\.title))")

        let music = try #require(sections.first { $0.title == "Music" })
        let artists = try await library.artists(inSection: music.key)
        #expect(artists.count > 1)
        print("→ \(artists.count) artists")

        // Walk until an artist with albums that have tracks turns up.
        var checked = 0
        for artist in artists {
            let albums = try await library.albums(forArtist: artist.ratingKey, inSection: music.key)
            guard let album = albums.first else { continue }
            let tracks = try await library.tracks(inAlbum: album.ratingKey)
            guard let track = tracks.first else { continue }

            print("→ \(artist.title) / \(album.title) (\(tracks.count) tracks)")
            #expect(track.part != nil)
            #expect(track.media?.first?.audioCodec != nil)

            let stream = try #require(library.streamURL(for: track))
            #expect(stream.absoluteString.contains("/library/parts/"))
            print("→ codec \(track.media?.first?.audioCodec ?? "?"), \(Int(track.durationSeconds ?? 0))s")

            let artwork = try #require(library.artworkURL(album.thumb))
            #expect(artwork.absoluteString.contains("/photo/:/transcode"))
            checked += 1
            break
        }
        #expect(checked == 1, "no artist with a playable album was found")
    }
}
