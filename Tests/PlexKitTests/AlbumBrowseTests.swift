import Foundation
import Testing
@testable import PlexKit

@Suite("Album browse")
struct AlbumBrowseTests {
    static let day = 86_400
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ days: Int) -> Int { Int(now.timeIntervalSince1970) - days * day }

    static func album(
        _ title: String,
        artist: String,
        year: Int? = nil,
        released: String? = nil,
        added: Int? = nil,
        played: Int? = nil,
        plays: Int? = nil,
        genres: [String] = []
    ) -> PlexAlbum {
        PlexAlbum(
            ratingKey: "\(artist)/\(title)", title: title,
            parentRatingKey: artist, parentTitle: artist, year: year, thumb: nil,
            addedAt: added, lastViewedAt: played, viewCount: plays,
            originallyAvailableAt: released, genres: genres
        )
    }

    static let albums = [
        album("Revolver", artist: "The Beatles", year: 1966, released: "1966-08-05", added: 100, played: ago(2), plays: 66, genres: ["Pop/Rock"]),
        album("Rubber Soul", artist: "The Beatles", year: 1965, released: "1965-12-03", added: 101, played: ago(40), plays: 45, genres: ["Pop/Rock"]),
        album("Soulmate Stuff", artist: "Antarctigo Vespucci", year: 2014, released: "2014-04-08", added: 300, played: ago(0), plays: 32, genres: ["Punk", "Pop/Rock"]),
        album("Demos", artist: "Nobody", added: 200),
    ]

    @Test("decodes the browse fields from a real album payload")
    func decoding() throws {
        let body = try Fixture.data("albums")
        let albums = try JSONDecoder().decode(MediaContainerResponse<PlexAlbum>.self, from: body).items
        let abbey = try #require(albums.first { $0.title.hasPrefix("Abbey Road") })
        #expect(abbey.addedAt == 1_777_503_638)
        #expect(abbey.lastViewedAt == 1_788_284_819)
        #expect(abbey.viewCount == 93)
        #expect(abbey.originallyAvailableAt == "1969-09-26")
        #expect(abbey.genres == ["Pop/Rock"])
        let soulmate = try #require(albums.first { $0.title == "Soulmate Stuff" })
        #expect(soulmate.genres.isEmpty)
    }

    @Test("each view sorts its way, missing keys last, titles breaking ties", arguments: [
        (AlbumView.recentlyAdded, ["Soulmate Stuff", "Demos", "Rubber Soul", "Revolver"]),
        (.mostPlayed, ["Revolver", "Rubber Soul", "Soulmate Stuff", "Demos"]),
        (.artist, ["Soulmate Stuff", "Revolver", "Rubber Soul", "Demos"]),
    ])
    func sorting(view: AlbumView, expected: [String]) {
        #expect(view.sort.sorted(Self.albums).map(\.title) == expected)
    }

    @Test("back catalog runs least recently played first, never played at the top")
    func backCatalogSort() {
        #expect(AlbumView.backCatalog.sort.sorted(Self.albums).map(\.title)
            == ["Demos", "Rubber Soul", "Revolver", "Soulmate Stuff"])
    }

    @Test("artists sort by the same keys, with the artist view reading as name")
    func artistSorting() {
        let a = PlexArtist(ratingKey: "1", title: "Zed", addedAt: 10, lastViewedAt: nil, viewCount: 5)
        let b = PlexArtist(ratingKey: "2", title: "Amy", addedAt: 20, lastViewedAt: 1, viewCount: nil)
        #expect(AlbumView.recentlyAdded.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
        #expect(AlbumView.mostPlayed.sorted([a, b]).map(\.title) == ["Zed", "Amy"])
        #expect(AlbumView.artist.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
        #expect(AlbumView.backCatalog.sorted([a, b]).map(\.title) == ["Zed", "Amy"])
    }

    @Test("release date falls back to the year when the server has no day")
    func releaseFallback() {
        let dated = Self.album("A", artist: "x", year: 2000, released: "2000-06-01")
        let yearOnly = Self.album("B", artist: "x", year: 2000)
        let later = Self.album("C", artist: "x", year: 2001)
        #expect(AlbumSort.releaseDate.sorted([yearOnly, dated, later]).map(\.title) == ["C", "A", "B"])
    }

    @Test("artist view groups A–Z with each artist's albums newest release first")
    func artistGroups() {
        let groups = AlbumBrowse.groups(Self.albums, view: .artist)
        #expect(groups.map(\.name) == ["Antarctigo Vespucci", "Nobody", "The Beatles"])
        #expect(groups[2].albums.map(\.title) == ["Revolver", "Rubber Soul"])
    }

    @Test("hidden artists drop out of groups and search")
    func hiding() {
        let groups = AlbumBrowse.groups(Self.albums, view: .artist, hiding: ["The Beatles"])
        #expect(groups.map(\.name) == ["Antarctigo Vespucci", "Nobody"])
        let hits = AlbumBrowse.search(Self.albums, query: "soul", view: .artist, hiding: ["The Beatles"])
        #expect(hits.map(\.title) == ["Soulmate Stuff"])
    }

    @Test("flat views are one nameless group in sort order")
    func ungrouped() {
        let groups = AlbumBrowse.groups(Self.albums, view: .mostPlayed)
        #expect(groups.count == 1)
        #expect(groups[0].name.isEmpty)
        #expect(groups[0].albums.map(\.title) == ["Revolver", "Rubber Soul", "Soulmate Stuff", "Demos"])
    }

    @Test("back catalog buckets run from never to today, oldest play first inside each")
    func recencyGroups() {
        let albums = Self.albums + [
            Self.album("Old", artist: "x", played: Self.ago(400)),
            Self.album("Older", artist: "x", played: Self.ago(200)),
            Self.album("Oldest", artist: "x", played: Self.ago(300)),
        ]
        let groups = AlbumBrowse.groups(albums, view: .backCatalog, now: Self.now)
        #expect(groups.map(\.name) == ["Never Played", "It's Been a While", "Played in the Last Year", "Played in the Last 6 Months", "Played in the Last Week", "Played Today"])
        #expect(groups[2].albums.map(\.title) == ["Oldest", "Older"])
    }

    @Test("search ranks prefix over word over internal, album over artist")
    func searchRanking() {
        let albums = [
            Self.album("Something Else", artist: "Reo Speedwagon"),   // artist prefix
            Self.album("The Real Thing", artist: "Faith No More"),    // album word-prefix
            Self.album("Careless", artist: "Someone"),                // album internal
            Self.album("Revolver", artist: "The Beatles"),            // album prefix
            Self.album("Hits", artist: "Dire Straits"),               // artist internal
            Self.album("Best Of", artist: "Lou Reed"),                // artist word-prefix
        ]
        let hits = AlbumBrowse.search(albums, query: "re", view: .artist)
        #expect(hits.map(\.title) == [
            "Revolver", "Something Else", "The Real Thing", "Best Of", "Careless", "Hits",
        ])
    }

    @Test("search is flat, trims, and is empty for a blank query")
    func searchBasics() {
        #expect(AlbumBrowse.search(Self.albums, query: "  ", view: .artist).isEmpty)
        let hits = AlbumBrowse.search(Self.albums, query: " beatles ", view: .artist)
        #expect(hits.map(\.title) == ["Revolver", "Rubber Soul"])
    }
}
