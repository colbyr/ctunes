import Foundation
import Testing
@testable import PlexKit

@Suite("Library search")
struct LibrarySearchTests {
    static func artist(_ key: String, _ title: String) -> PlexArtist {
        PlexArtist(ratingKey: key, title: title)
    }

    static func album(_ key: String, _ title: String, artist: (key: String, title: String)) -> PlexAlbum {
        PlexAlbum(ratingKey: key, title: title, parentRatingKey: artist.key, parentTitle: artist.title, year: nil, thumb: nil)
    }

    /// A track on one of the albums above, keyed like the artist and
    /// album so vetoes reach it.
    static func track(_ key: String, _ title: String, album: String, credited: String? = nil) -> PlexTrack {
        let album = albums.first { $0.ratingKey == album }!
        let credit = credited.map { ",\"originalTitle\":\"\($0)\"" } ?? ""
        let json = """
        {"ratingKey":"\(key)","title":"\(title)","parentRatingKey":"\(album.ratingKey)","parentTitle":"\(album.title)",
         "grandparentRatingKey":"\(album.parentRatingKey!)","grandparentTitle":"\(album.parentTitle!)"\(credit)}
        """
        return try! JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    static let velvet = (key: "vu", title: "The Velvet Underground")
    static let cranberries = (key: "cb", title: "The Cranberries")
    static let valley = (key: "sv", title: "Sunday Valley")
    static let artists = [artist(velvet.key, velvet.title), artist(cranberries.key, cranberries.title), artist(valley.key, valley.title)]
    static let albums = [
        album("nico", "The Velvet Underground & Nico", artist: velvet),
        album("loaded", "Loaded", artist: velvet),
        album("everybody", "Everybody Else Is Doing It", artist: cranberries),
        album("bloody", "Bloody Sunday Sessions", artist: cranberries),
        album("given", "Given", artist: valley),
    ]
    // What the server hands back for "sunday": a word prefix in the
    // title, the album or the artist.
    static let tracks = [
        track("t1", "Femme Fatale", album: "nico"),
        track("t2", "Sunday Morning", album: "nico"),
        track("t3", "Sunday", album: "everybody"),
        track("t4", "Lazy Sunday", album: "loaded"),
        track("t5", "Sessions Intro", album: "bloody"),
        track("t6", "Any Given Day", album: "given"),
    ]

    @Test("ranks own-name prefix, word, inside, then a parent's name, artist before album before track")
    func ranking() {
        // The tracks the server would return for the query, as in the app.
        let tracks = Self.tracks.filter { LibrarySearch.matches($0, query: "sunday") }
        let hits = LibrarySearch.hits(artists: Self.artists, albums: Self.albums, tracks: tracks, query: "sunday")
        #expect(hits.map(\.id) == [
            "artist:sv",          // prefix, artist
            "track:t2",           // prefix, track ("Sunday Morning"), in server order
            "track:t3",           // prefix, track ("Sunday")
            "album:bloody",       // word prefix, album ("Bloody Sunday Sessions")
            "track:t4",           // word prefix, track ("Lazy Sunday")
            "album:given",        // matched through the artist's name
            "track:t5",           // matched through the album's name
            "track:t6",           // matched through the artist's name
        ])
    }

    @Test("a track the server matched on nothing the phone can see still lists, last")
    func elsewhere() {
        let hits = LibrarySearch.hits(artists: [], albums: [], tracks: Self.tracks, query: "sunday velvet")
        #expect(hits.map(\.id) == Self.tracks.map { "track:\($0.ratingKey)" })
    }

    @Test("hidden artists, albums and tracks drop out, and albums by a hidden artist with them")
    func hidden() {
        let hidden = VetoSet(artists: [Self.velvet.key], tracks: ["t3"])
        // The tracks the server would return for the query, as in the app.
        let velvet = Self.tracks.filter { LibrarySearch.matches($0, query: "velvet") }
        #expect(velvet.count == 3)
        let hits = LibrarySearch.hits(artists: Self.artists, albums: Self.albums, tracks: velvet, query: "velvet", hiding: hidden)
        #expect(hits.isEmpty)
        let sunday = LibrarySearch.hits(artists: Self.artists, albums: Self.albums, tracks: Self.tracks, query: "sunday", hiding: hidden)
        #expect(sunday.map(\.id) == ["artist:sv", "album:bloody", "album:given", "track:t5", "track:t6"])
    }

    @Test("only the best tracks are kept, and a blank query is nothing")
    func trackLimit() {
        let hits = LibrarySearch.hits(artists: [], albums: [], tracks: Self.tracks, query: "sunday", trackLimit: 2)
        #expect(hits.map(\.id) == ["track:t2", "track:t3"])
        #expect(LibrarySearch.hits(artists: Self.artists, albums: Self.albums, tracks: Self.tracks, query: "  ").isEmpty)
    }

    @Test("completions are matching artist and album names, best first, never the query itself")
    func completions() {
        #expect(LibrarySearch.completions(artists: Self.artists, albums: Self.albums, query: "the velvet")
            == ["The Velvet Underground", "The Velvet Underground & Nico"])
        #expect(LibrarySearch.completions(artists: Self.artists, albums: Self.albums, query: "The Velvet Underground")
            == ["The Velvet Underground & Nico"])
        #expect(LibrarySearch.completions(artists: Self.artists, albums: Self.albums, query: "sunday", limit: 1)
            == ["Sunday Valley"])
    }

    @Test("the offline match is the server's: every query word starts a word of the title, album or artist")
    func offlineMatch() {
        let morning = Self.tracks[1]
        #expect(LibrarySearch.matches(morning, query: "sunday"))
        #expect(LibrarySearch.matches(morning, query: "Sund"))
        #expect(LibrarySearch.matches(morning, query: "velvet"))
        #expect(LibrarySearch.matches(morning, query: "sunday velvet"))
        #expect(!LibrarySearch.matches(morning, query: "unday"))
        #expect(!LibrarySearch.matches(morning, query: "sunday cranberries"))
        #expect(!LibrarySearch.matches(morning, query: " "))
        let credited = Self.track("t9", "Duet", album: "loaded", credited: "Nico & Lou Reed")
        #expect(LibrarySearch.matches(credited, query: "lou"))
    }
}
