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
        // `/albums`, not `all?type=9`: the same list, plus leafCount.
        #expect(url.contains("/library/sections/3/albums"))
        #expect(!url.contains("artist.id"))

        // The grouping key comes off the album, so it has to decode.
        let first = try #require(albums.first)
        #expect(first.parentRatingKey == "1028")
        let abbey = try #require(albums.first { $0.title.hasPrefix("Abbey Road") })
        #expect(abbey.leafCount == 17)
    }

    @Test("play history asks for the section since a date, newest first")
    func playHistoryQuery() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("history")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let plays = try await library.playHistory(inSection: "3", since: Date(timeIntervalSince1970: 1_700_000_000))
        let url = try #require(seen.get())
        #expect(url.contains("/status/sessions/history/all"))
        #expect(url.contains("librarySectionID=3"))
        // The server accepts `%3E=`, which is how Foundation encodes `>=`;
        // fully encoding it as `%3E%3D` is a 400.
        #expect(url.contains("viewedAt%3E=1700000000"))
        #expect(url.contains("sort=viewedAt:desc"))
        #expect(plays.count == 9)
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
        #expect(first.parentRatingKey == "1029")
        #expect(first.parentTitle == "Soulmate Stuff")

        let part = try #require(first.part)
        #expect(part.key == "/library/parts/1017/1746246593/file.flac")
        #expect(first.media?.first?.audioCodec == "flac")
        #expect(abs((first.durationSeconds ?? 0) - 98.061) < 0.001)
    }

    @Test("artist tracks query filters the section by artist")
    func tracksForArtist() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("tracks")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let tracks = try await library.tracks(forArtist: "1028", inSection: "3")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all"))
        #expect(url.contains("type=10"))
        #expect(url.contains("artist.id=1028"))
        #expect(!url.contains("/children"))
        #expect(tracks.count == 7)
        #expect(tracks.first?.grandparentRatingKey == "1028")
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
        // The rating's timestamp rides along, so the list can sort newest first.
        #expect(tracks.first { $0.ratingKey == "1030" }?.lastRatedAt == 1_788_313_957)
        #expect(tracks.first { $0.ratingKey == "1031" }?.lastRatedAt == nil)
    }

    @Test("every track in a section is one type=10 query")
    func sectionTracksQuery() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("tracks")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let tracks = try await library.tracks(inSection: "3")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all?type=10"))
        #expect(!url.contains("artist.id"))
        #expect(!tracks.isEmpty)
    }

    @Test("track search asks the section's title filter, trimmed, folded and percent-encoded")
    func searchTracksQuery() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("tracks")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let tracks = try await library.searchTracks(inSection: "3", query: "  Sunday Morning ")
        let url = try #require(seen.get())
        #expect(url.contains("/library/sections/3/all?type=10&title=sunday%20morning"))
        #expect(!tracks.isEmpty)
        // Nothing to ask for: no request at all.
        seen.set(nil)
        let none = try await library.searchTracks(inSection: "3", query: " ")
        #expect(none.isEmpty)
        #expect(seen.get() == nil)
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

    // MARK: - Playlists

    /// The fixture is the section-filtered list: a regular playlist with
    /// counts, smart ones, and an empty one with no composite or duration.
    @Test("decodes the section's playlists, smart as a real bool")
    func playlists() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("playlists")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let playlists = try await library.playlists(inSection: "3")
        let url = try #require(seen.get())
        #expect(url.hasSuffix("/playlists?playlistType=audio&sectionID=3"))
        #expect(playlists.count == 7)

        let regular = try #require(playlists.first { $0.ratingKey == "1251" })
        #expect(regular.title == "A Gentle Introduction to Laura Stevenson")
        #expect(!regular.smart)
        #expect(regular.leafCount == 7)
        #expect(regular.duration == 1_669_000)
        #expect(regular.composite == "/playlists/1251/composite/1756333152")
        #expect(regular.updatedAt == 1_756_333_152)
        #expect(regular.viewCount == 14)

        let smart = try #require(playlists.first { $0.ratingKey == "440" })
        #expect(smart.smart)
        #expect(smart.composite?.isEmpty == false)

        let empty = try #require(playlists.first { $0.ratingKey == "437" })
        #expect(empty.smart)
        #expect(empty.composite == nil)
        #expect(empty.duration == nil)
        #expect(empty.leafCount == 0)
    }

    @Test("a regular playlist's items carry their item id and the track's part")
    func playlistItems() async throws {
        let seen = Locked<String?>(nil)
        let body = try Fixture.string("playlist-items")
        let library = library { request in
            seen.set(request.url?.absoluteString)
            return .json(body)
        }

        let items = try await library.items(inPlaylist: "1251")
        #expect(seen.get()?.hasSuffix("/playlists/1251/items") == true)
        #expect(items.count == 7)
        // The playlist's order, not the ids': handles, not positions.
        #expect(items.prefix(3).map(\.playlistItemID) == [398, 399, 391])
        let first = items[0]
        #expect(first.track.ratingKey == "1212")
        #expect(first.track.title == "#1")
        #expect(first.track.grandparentTitle == "Laura Stevenson")
        #expect(first.track.parentRatingKey == "1138")
        #expect(first.track.part?.key == "/library/parts/1183/1750999050/file.flac")
        #expect(first.track.isFavorite)
    }

    @Test("a smart playlist's items have no item id")
    func smartPlaylistItems() async throws {
        let body = try Fixture.string("smart-playlist-items")
        let items = try await library { _ in .json(body) }.items(inPlaylist: "437")
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.playlistItemID == nil })
        #expect(items[0].track.title == "Sunday Morning")
        #expect(items[0].track.part != nil)
    }

    @Test("a playlist item round-trips through JSON in the server's shape")
    func playlistItemRoundTrip() throws {
        let items = try JSONDecoder().decode(
            MediaContainerResponse<PlaylistItem>.self, from: Fixture.data("playlist-items")
        ).items
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([PlaylistItem].self, from: data)
        #expect(decoded == items)
        // The id sits beside the track's own keys, not under a wrapper.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        #expect(object?["playlistItemID"] as? Int == 398)
        #expect(object?["ratingKey"] as? String == "1212")
    }

    @Test("create POSTs the title and the tracks' uri and returns the new entry")
    func createPlaylist() async throws {
        let seen = Locked<[String]>([])
        let body = try Fixture.string("playlists")
        let library = library { request in
            seen.set(seen.get() + ["\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"])
            return .json(body)
        }

        let playlist = try await library.createPlaylist(title: "ctunes scratch & test+1", trackKeys: ["1212", "609"])
        let call = try #require(seen.get().first)
        #expect(call.hasPrefix("POST https://example.plex.direct:32400/playlists?type=audio&smart=0"))
        // The strict encoder: a space, an ampersand and a plus all encoded.
        #expect(call.contains("title=ctunes%20scratch%20%26%20test%2B1"))
        #expect(call.hasSuffix("uri=server://M/com.plexapp.plugins.library/library/metadata/1212,609"))
        #expect(playlist.ratingKey == "440")
    }

    @Test("append PUTs the tracks' uri and reads how many were new")
    func addToPlaylist() async throws {
        let seen = Locked<[String]>([])
        let library = library { request in
            seen.set(seen.get() + ["\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"])
            return .json(#"{"MediaContainer":{"size":1,"leafCountAdded":1,"leafCountRequested":2}}"#)
        }

        let added = try await library.add(trackKeys: ["580", "1212"], toPlaylist: "1251")
        #expect(added == 1)
        let call = try #require(seen.get().first)
        #expect(call == "PUT https://example.plex.direct:32400/playlists/1251/items?uri=server://M/com.plexapp.plugins.library/library/metadata/580,1212")

        // Nothing to add is no request.
        #expect(try await library.add(trackKeys: [], toPlaylist: "1251") == 0)
        #expect(seen.get().count == 1)
    }

    @Test("remove, move, rename and delete address the item and the playlist")
    func playlistEdits() async throws {
        let seen = Locked<[String]>([])
        let library = library { request in
            seen.set(seen.get() + ["\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"])
            return .init(body: Data())
        }

        try await library.remove(item: 398, fromPlaylist: "1251")
        try await library.move(item: 391, after: 399, inPlaylist: "1251")
        try await library.move(item: 391, after: nil, inPlaylist: "1251")
        try await library.renamePlaylist("1251", title: "Road Trip")
        try await library.deletePlaylist("1251")

        #expect(seen.get() == [
            "DELETE https://example.plex.direct:32400/playlists/1251/items/398",
            "PUT https://example.plex.direct:32400/playlists/1251/items/391/move?after=399",
            "PUT https://example.plex.direct:32400/playlists/1251/items/391/move",
            "PUT https://example.plex.direct:32400/playlists/1251?title=Road%20Trip",
            "DELETE https://example.plex.direct:32400/playlists/1251",
        ])
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

    @Test("transcoded stream URL asks the universal transcoder for HLS at the bitrate")
    func transcodedStreamURL() async throws {
        let body = try Fixture.string("tracks")
        let library = library { _ in .json(body) }
        let track = try #require(try await library.tracks(inAlbum: "1029").first)

        let url = try #require(library.streamURL(for: track, quality: .kbps192, sessionIdentifier: "S1"))
        let string = url.absoluteString
        #expect(string.hasPrefix("https://example.plex.direct:32400/music/:/transcode/universal/start.m3u8?"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("path") == "/library/metadata/\(track.ratingKey)")
        #expect(value("protocol") == "hls")
        #expect(value("directPlay") == "0")
        #expect(value("directStream") == "0")
        #expect(value("fastSeek") == "1")
        #expect(value("musicBitrate") == "192")
        #expect(value("session") == "S1")
        #expect(value("X-Plex-Session-Identifier") == "S1")
        #expect(value("X-Plex-Token") == "TOKEN")
        #expect(value("X-Plex-Client-Identifier") == "TEST")
        #expect(value("X-Plex-Platform") == "iOS")
        // Decoded whole: the server splits on a bare `&` inside it.
        #expect(value("X-Plex-Client-Profile-Extra")?.hasPrefix("add-transcode-target(type=musicProfile&") == true)
        #expect(string.contains("audioCodec%3Daac%29"))

        let original = try #require(library.streamURL(for: track, quality: .original, sessionIdentifier: "S1"))
        #expect(original == library.streamURL(for: track))
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
