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
        #expect(groups.map(\.name) == ["Never Played", "It's Been a While", "Last Year", "Last 6 Months", "Last Week", "Played Today"])
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

@Suite("On Rotation")
struct RotationTests {
    static let day: TimeInterval = 86_400
    static let now = AlbumBrowseTests.now
    static func play(_ album: String, daysAgo: Double, artist: String? = nil) -> PlayHistoryEntry {
        PlayHistoryEntry(albumRatingKey: album, artistRatingKey: artist, viewedAt: Int(now.timeIntervalSince1970 - daysAgo * day))
    }
    static func album(_ key: String, artist: String = "a", tracks: Int? = 10, plays: Int? = nil) -> PlexAlbum {
        PlexAlbum(ratingKey: key, title: key, parentRatingKey: artist, parentTitle: artist, year: nil, thumb: nil,
                  viewCount: plays, leafCount: tracks)
    }

    @Test("decodes plays from the history payload, reducing key paths to rating keys")
    func decoding() throws {
        let body = try Fixture.data("history")
        let plays = try JSONDecoder().decode(MediaContainerResponse<PlayHistoryEntry>.self, from: body).items
        #expect(plays.count == 9)
        #expect(plays[0].albumRatingKey == "3144")
        #expect(plays[0].artistRatingKey == "2323")
        #expect(plays[0].viewedAt == 1_788_827_321)
        // A play the server no longer ties to an album decodes, without one.
        #expect(plays[8].albumRatingKey == nil)
    }

    @Test("round-trips through the snapshot in reduced form")
    func roundTrip() throws {
        let plays = try JSONDecoder().decode(
            MediaContainerResponse<PlayHistoryEntry>.self, from: Fixture.data("history")
        ).items
        let data = try JSONEncoder().encode(plays)
        #expect(try JSONDecoder().decode([PlayHistoryEntry].self, from: data) == plays)
    }

    @Test("recent plays outweigh many old ones")
    func decay() {
        // 10 plays this week against 30 spread over the year.
        let recent = (0..<10).map { Self.play("new", daysAgo: Double($0 % 7)) }
        let old = (0..<30).map { Self.play("old", daysAgo: Double($0) * 12 + 10) }
        let rotation = Rotation(history: recent + old, albums: [Self.album("new"), Self.album("old")], now: Self.now)
        #expect(rotation.albums["new"]! > rotation.albums["old"]!)
        // A play today is worth 1; one a half-life ago is worth half.
        let single = Rotation(history: [Self.play("x", daysAgo: 60)], albums: [Self.album("x", tracks: 1)], now: Self.now)
        #expect(abs(single.albums["x"]! - 0.5) < 0.001)
    }

    @Test("divides by the square root of the track count, so neither length nor brevity wins")
    func perTrack() {
        // A 16-track album played through once (16 plays) scores 4; a
        // single played 4 times scores 4 too; played twice, it scores 2.
        let plays = (0..<16).map { _ in Self.play("long", daysAgo: 0) } + (0..<2).map { _ in Self.play("single", daysAgo: 0) }
        let rotation = Rotation(history: plays, albums: [Self.album("long", tracks: 16), Self.album("single", tracks: 1)], now: Self.now)
        #expect(rotation.albums["long"]! == 4)
        #expect(rotation.albums["single"]! == 2)
        // No count known: taken as one track, and the artist sums its albums.
        let bare = Rotation(history: [Self.play("b", daysAgo: 0), Self.play("four", daysAgo: 0)],
                            albums: [Self.album("b", tracks: nil), Self.album("four", tracks: 4)], now: Self.now)
        #expect(bare.albums["b"] == 1)
        #expect(bare.artists["a"] == 1.5)
    }

    @Test("plays of albums no longer in the library are dropped")
    func unknownAlbums() {
        let rotation = Rotation(history: [Self.play("gone", daysAgo: 0), Self.play("here", daysAgo: 0)],
                                albums: [Self.album("here")], now: Self.now)
        #expect(rotation.albums.keys.sorted() == ["here"])
    }

    @Test("the view orders by score, unplayed albums last, and by play count without history")
    func sorting() {
        let albums = [Self.album("quiet", plays: 500), Self.album("loud", plays: 3), Self.album("never", plays: nil)]
        let rotation = Rotation(history: [Self.play("loud", daysAgo: 1), Self.play("quiet", daysAgo: 300)], albums: albums, now: Self.now)
        #expect(AlbumView.mostPlayed.sorted(albums, rotation: rotation).map(\.ratingKey) == ["loud", "quiet", "never"])
        #expect(AlbumView.mostPlayed.sorted(albums).map(\.ratingKey) == ["quiet", "loud", "never"])
        let groups = AlbumBrowse.groups(albums, view: .mostPlayed, rotation: rotation)
        #expect(groups.first?.albums.map(\.ratingKey) == ["loud", "quiet", "never"])
    }

    @Test("artists order by the sum of their albums' scores")
    func artists() {
        let artists = [
            PlexArtist(ratingKey: "a", title: "A", thumb: nil, viewCount: 900),
            PlexArtist(ratingKey: "b", title: "B", thumb: nil, viewCount: 1),
        ]
        let albums = [Self.album("a1", artist: "a", tracks: 1), Self.album("b1", artist: "b", tracks: 1), Self.album("b2", artist: "b", tracks: 1)]
        let rotation = Rotation(history: [Self.play("a1", daysAgo: 0), Self.play("b1", daysAgo: 0), Self.play("b2", daysAgo: 0)], albums: albums, now: Self.now)
        #expect(AlbumView.mostPlayed.sorted(artists, rotation: rotation).map(\.ratingKey) == ["b", "a"])
        #expect(AlbumView.mostPlayed.sorted(artists).map(\.ratingKey) == ["a", "b"])
    }

    @Test("On Rotation is first in the menu")
    func menuOrder() {
        #expect(AlbumView.allCases.first == .mostPlayed)
        #expect(AlbumView.mostPlayed.title == "On Rotation")
    }
}
