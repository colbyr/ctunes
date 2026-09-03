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

    @Test("sorts with missing keys last and titles breaking ties", arguments: [
        (AlbumSort.recentlyAdded, ["Soulmate Stuff", "Demos", "Rubber Soul", "Revolver"]),
        (.lastPlayed, ["Soulmate Stuff", "Revolver", "Rubber Soul", "Demos"]),
        (.releaseDate, ["Soulmate Stuff", "Revolver", "Rubber Soul", "Demos"]),
        (.playCount, ["Revolver", "Rubber Soul", "Soulmate Stuff", "Demos"]),
        (.name, ["Demos", "Revolver", "Rubber Soul", "Soulmate Stuff"]),
    ])
    func sorting(sort: AlbumSort, expected: [String]) {
        #expect(sort.sorted(Self.albums).map(\.title) == expected)
    }

    @Test("artists sort by the same keys, with release date reading as name")
    func artistSorting() {
        let a = PlexArtist(ratingKey: "1", title: "Zed", addedAt: 10, lastViewedAt: nil, viewCount: 5)
        let b = PlexArtist(ratingKey: "2", title: "Amy", addedAt: 20, lastViewedAt: 1, viewCount: nil)
        #expect(AlbumSort.recentlyAdded.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
        #expect(AlbumSort.lastPlayed.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
        #expect(AlbumSort.playCount.sorted([a, b]).map(\.title) == ["Zed", "Amy"])
        #expect(AlbumSort.releaseDate.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
        #expect(AlbumSort.name.sorted([a, b]).map(\.title) == ["Amy", "Zed"])
    }

    @Test("release date falls back to the year when the server has no day")
    func releaseFallback() {
        let dated = Self.album("A", artist: "x", year: 2000, released: "2000-06-01")
        let yearOnly = Self.album("B", artist: "x", year: 2000)
        let later = Self.album("C", artist: "x", year: 2001)
        #expect(AlbumSort.releaseDate.sorted([yearOnly, dated, later]).map(\.title) == ["C", "A", "B"])
    }

    @Test("artist groups follow the sort by their top album")
    func artistGroupsFollowSort() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .playCount, grouping: .artist)
        #expect(groups.map(\.name) == ["The Beatles", "Antarctigo Vespucci", "Nobody"])
        #expect(groups[0].albums.map(\.title) == ["Revolver", "Rubber Soul"])
    }

    @Test("artist groups go alphabetical under the name sort")
    func artistGroupsByName() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .name, grouping: .artist)
        #expect(groups.map(\.name) == ["Antarctigo Vespucci", "Nobody", "The Beatles"])
    }

    @Test("hidden artists drop out of groups and search")
    func hiding() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .name, grouping: .artist, hiding: ["The Beatles"])
        #expect(groups.map(\.name) == ["Antarctigo Vespucci", "Nobody"])
        let hits = AlbumBrowse.search(Self.albums, query: "soul", sort: .name, hiding: ["The Beatles"])
        #expect(hits.map(\.title) == ["Soulmate Stuff"])
    }

    @Test("no grouping is one flat nameless group in sort order")
    func ungrouped() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .playCount, grouping: .none)
        #expect(groups.count == 1)
        #expect(groups[0].name.isEmpty)
        #expect(groups[0].albums.map(\.title) == ["Revolver", "Rubber Soul", "Soulmate Stuff", "Demos"])
    }

    @Test("year groups stay newest first whatever the sort")
    func yearGroups() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .playCount, grouping: .releaseYear)
        #expect(groups.map(\.name) == ["2014", "1966", "1965", "Unknown Year"])
    }

    @Test("decade groups run oldest first, newest first under the release sort, unknown last")
    func decadeGroups() {
        let byTitle = AlbumBrowse.groups(Self.albums, sort: .name, grouping: .decade)
        #expect(byTitle.map(\.name) == ["1960s", "2010s", "Unknown Decade"])
        #expect(byTitle[0].albums.map(\.title) == ["Revolver", "Rubber Soul"])
        let newest = AlbumBrowse.groups(Self.albums, sort: .releaseDate, grouping: .decade)
        #expect(newest.map(\.name) == ["2010s", "1960s", "Unknown Decade"])
    }

    @Test("an album lands in every one of its genres")
    func genreGroups() {
        let groups = AlbumBrowse.groups(Self.albums, sort: .name, grouping: .genre)
        #expect(groups.map(\.name) == ["No Genre", "Pop/Rock", "Punk"])
        #expect(groups[1].albums.count == 3)
    }

    @Test("last played buckets run from today to never")
    func recencyGroups() {
        let albums = Self.albums + [
            Self.album("Old", artist: "x", played: Self.ago(400)),
            Self.album("Older", artist: "x", played: Self.ago(200)),
        ]
        let groups = AlbumBrowse.groups(albums, sort: .lastPlayed, grouping: .lastPlayed, now: Self.now)
        #expect(groups.map(\.name) == ["Today", "Past Week", "Past 6 Months", "Past Year", "Earlier", "Never Played"])
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
        let hits = AlbumBrowse.search(albums, query: "re", sort: .name)
        #expect(hits.map(\.title) == [
            "Revolver", "Something Else", "The Real Thing", "Best Of", "Careless", "Hits",
        ])
    }

    @Test("search is flat, trims, and is empty for a blank query")
    func searchBasics() {
        #expect(AlbumBrowse.search(Self.albums, query: "  ", sort: .name).isEmpty)
        let hits = AlbumBrowse.search(Self.albums, query: " beatles ", sort: .name)
        #expect(hits.map(\.title) == ["Revolver", "Rubber Soul"])
    }
}
