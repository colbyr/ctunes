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

    @Test("lists every album in a section for the grouped browse list")
    func allAlbums() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("albums")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let albums = try await library.albums(inSection: "3")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all"))
        #expect(url.contains("type=9"))
        #expect(!url.contains("artist.id"))

        // The grouping key comes off the album, so it has to decode.
        let first = try #require(albums.first)
        #expect(first.parentRatingKey == "1028")
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

        #expect(tracks.count == 7)
        let first = try #require(tracks.first)
        #expect(first.title == "100 Years")
        #expect(first.index == 1)
        #expect(first.grandparentTitle == "Antarctigo Vespucci")
        #expect(first.grandparentRatingKey == "1028")
        #expect(first.parentTitle == "Soulmate Stuff")

        let part = try #require(first.part)
        #expect(part.key == "/library/parts/1017/1746246593/file.flac")
        #expect(first.media?.first?.audioCodec == "flac")
        #expect(abs((first.durationSeconds ?? 0) - 98.061) < 0.001)
    }

    /// The fixture credits one track to a featured artist and puts the last
    /// two on a second disc.
    @Test("decodes the credited artist and disc number")
    func trackArtistAndDisc() async throws {
        let body = try Fixture.string("tracks")
        let tracks = try await library { _ in .json(body) }.tracks(inAlbum: "1029")

        #expect(tracks[0].trackArtist == nil)
        #expect(tracks[1].trackArtist == "Antarctigo Vespucci feat. Laura Stevenson")
        #expect(tracks.map(\.parentIndex) == [1, 1, 1, 1, 1, 2, 2])
    }

    /// The fixture has two tracks rated 10 and five never rated.
    @Test("a full 10 is a favorite, an absent rating is not")
    func favorite() async throws {
        let body = try Fixture.string("tracks")
        let tracks = try await library { _ in .json(body) }.tracks(inAlbum: "1029")

        let favorites = tracks.filter(\.isFavorite).map(\.ratingKey)
        #expect(favorites == ["1030", "1034"])
        #expect(tracks.first { $0.ratingKey == "1031" }?.userRating == nil)
    }

    @Test("favorite tracks query matches rating 10 exactly")
    func favoriteTracksQuery() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("tracks")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        _ = try await library.favoriteTracks(inSection: "3")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all"))
        #expect(url.contains("type=10"))
        #expect(url.contains("userRating=10"))
    }

    @Test("favoriting a track PUTs a 10 to /:/rate, unfavoriting PUTs -1")
    func setFavorite() async throws {
        let seen = Locked<[String]>([])
        let library = library { request in
            seen.set(seen.get() + ["\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"])
            return .init(body: Data())
        }

        try await library.setFavorite("1030", true)
        try await library.setFavorite("1030", false)

        let calls = seen.get()
        #expect(calls.count == 2)
        #expect(calls[0].hasPrefix("PUT https://example.plex.direct:32400/:/rate?"))
        #expect(calls[0].contains("identifier=com.plexapp.plugins.library"))
        #expect(calls[0].contains("key=1030"))
        #expect(calls[0].hasSuffix("rating=10"))
        #expect(calls[1].hasSuffix("rating=-1"))
    }

    @Test("timeline reports carry state, progress and a session id")
    func reportTimeline() async throws {
        let tracksBody = try Fixture.string("tracks")
        let seen = Locked<[URLRequest]>([])
        let library = library { request in
            guard request.url?.path.hasSuffix("/timeline") == true else { return .json(tracksBody) }
            seen.set(seen.get() + [request])
            return .init(body: Data())
        }
        let track = try #require(try await library.tracks(inAlbum: "1029").first)

        try await library.reportTimeline(track, state: .playing, time: 12.5, sessionIdentifier: "S1")
        try await library.reportTimeline(track, state: .stopped, time: 0, sessionIdentifier: "S1")

        let calls = seen.get()
        #expect(calls.count == 2)
        let first = calls[0].url?.absoluteString ?? ""
        #expect(first.hasPrefix("https://example.plex.direct:32400/:/timeline?"))
        #expect(first.contains("ratingKey=\(track.ratingKey)"))
        #expect(first.contains("key=/library/metadata/\(track.ratingKey)"))
        #expect(first.contains("state=playing"))
        #expect(first.contains("time=12500"))
        #expect(first.contains("duration=\(track.duration ?? -1)"))
        #expect(calls[0].value(forHTTPHeaderField: "X-Plex-Session-Identifier") == "S1")
        #expect(calls[0].value(forHTTPHeaderField: "X-Plex-Token") == "TOKEN")
        #expect(calls[1].url?.absoluteString.contains("state=stopped") == true)
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
