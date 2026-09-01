import Foundation
import Testing
@testable import PlexKit

@Suite("Library decoding")
struct PlexLibraryTests {
    static let server = PlexServer(
        name: "Test",
        machineIdentifier: "M",
        baseURL: URL(string: "https://example.plex.direct:32400")!,
        isLocal: true
    )

    private func library(
        handler: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response
    ) -> PlexLibrary {
        PlexLibrary(
            client: PlexClient(
                identity: PlexIdentity(clientIdentifier: "TEST"),
                session: MockURLProtocol.session(handler: handler)
            ),
            server: Self.server,
            token: "TOKEN"
        )
    }

    @Test("finds both music libraries and skips video ones")
    func musicSections() async throws {
        let body = try Fixture.string("sections")
        let sections = try await library { _ in .json(body) }.musicSections()

        #expect(sections.map(\.title) == ["Audio Books", "Music"])
        let allMusic = sections.allSatisfy { $0.isMusic }
        #expect(allMusic)
    }

    /// ratingKey is a string in the payload even though it reads as a number.
    @Test("decodes artists with string rating keys")
    func artists() async throws {
        let body = try Fixture.string("artists")
        let artists = try await library { _ in .json(body) }.artists(inSection: "3")

        #expect(artists.count == 4)
        let first = try #require(artists.first)
        #expect(first.ratingKey == "1028")
        #expect(first.title == "Antarctigo Vespucci")
        #expect(first.thumb?.isEmpty == false)
    }

    @Test("decodes albums with year and artist")
    func albums() async throws {
        let body = try Fixture.string("albums")
        let albums = try await library { _ in .json(body) }.albums(forArtist: "1028", inSection: "3")

        #expect(albums.count == 4)
        let beatles = try #require(albums.first { $0.title.contains("Abbey Road") })
        #expect(beatles.parentTitle == "The Beatles")
        #expect(beatles.year == 1969)
    }

    /// The bug this avoids: /children under-reports albums for some artists.
    @Test("albums query filters by artist rather than walking children")
    func albumsUsesFilteredQuery() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("albums")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        _ = try await library.albums(forArtist: "1028", inSection: "3")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all"))
        #expect(url.contains("type=9"))
        #expect(url.contains("artist.id=1028"))
        #expect(!url.contains("/children"))
    }

    @Test("decodes tracks with their media parts")
    func tracks() async throws {
        let body = try Fixture.string("tracks")
        let tracks = try await library { _ in .json(body) }.tracks(inAlbum: "1029")

        #expect(tracks.count == 4)
        let first = try #require(tracks.first)
        #expect(first.title == "100 Years")
        #expect(first.index == 1)
        #expect(first.grandparentTitle == "Antarctigo Vespucci")
        #expect(first.parentTitle == "Soulmate Stuff")

        let part = try #require(first.part)
        #expect(part.key == "/library/parts/1017/1746246593/file.flac")
        #expect(first.media?.first?.audioCodec == "flac")
        #expect(abs((first.durationSeconds ?? 0) - 98.061) < 0.001)
    }

    @Test("stream URL carries the token in the query, not a header")
    func streamURL() async throws {
        let body = try Fixture.string("tracks")
        let library = library { _ in .json(body) }
        let track = try #require(try await library.tracks(inAlbum: "1029").first)

        let url = try #require(library.streamURL(for: track))
        #expect(url.absoluteString.hasPrefix("https://example.plex.direct:32400/library/parts/1017/"))
        #expect(url.absoluteString.hasSuffix("?X-Plex-Token=TOKEN"))
    }

    @Test("artwork URL goes through the photo transcoder")
    func artworkURL() async throws {
        let library = library { _ in .json("{}") }
        let url = library.artworkURL("/library/metadata/1028/thumb/178", size: 200)
        let string = try #require(url).absoluteString

        #expect(string.contains("/photo/:/transcode"))
        #expect(string.contains("width=200&height=200"))
        #expect(string.contains("url=%2Flibrary%2Fmetadata%2F1028%2Fthumb%2F178"))
    }

    @Test("artwork URL is nil when there is no thumb")
    func artworkURLNil() async {
        let library = library { _ in .json("{}") }
        #expect(library.artworkURL(nil) == nil)
        #expect(library.artworkURL("") == nil)
    }
}
