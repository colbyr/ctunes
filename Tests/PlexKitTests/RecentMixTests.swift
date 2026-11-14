import Foundation
import Testing
@testable import PlexKit

@Suite("Recent mixes")
struct RecentMixTests {
    private static let playlist = MixPick.playlist(ratingKey: "10", title: "Road Trip", thumb: nil)
    private static let artist = MixPick.artist(ratingKey: "20", title: "Bon Jovi", thumb: nil)
    private static let album = MixPick.album(ratingKey: "30", title: "Slippery When Wet", artistKey: "20", artist: "Bon Jovi", thumb: nil)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    @Test("the same picks in any order are the same mix, played again in the latest style")
    func sameSet() {
        var list = RecentMixes.recording([Self.artist, Self.album], style: .mixAlbums, at: Self.now, in: [])
        list = RecentMixes.recording([Self.album, Self.artist], style: .shuffle, at: Self.now + 60, in: list)
        #expect(list.count == 1)
        #expect(list[0].style == .shuffle)
        #expect(list[0].playCount == 2)
        #expect(list[0].picks == [Self.album, Self.artist])
    }

    @Test("a pinned mix is found by its set of picks")
    func pinnedKey() {
        let pinned = SavedMix(name: "Sunday", picks: [Self.playlist, Self.artist], style: .shuffle)
        #expect(pinned.pickKey == RecentMix.key(for: [Self.artist, Self.playlist]))
        #expect(pinned.pickKey != RecentMix.key(for: [Self.artist]))
    }

    @Test("nothing picked is never remembered")
    func emptyPicks() {
        #expect(RecentMixes.recording([], style: .shuffle, at: Self.now, in: []).isEmpty)
    }

    @Test("the last played leads, then the most played with recent plays counting most")
    func ranking() {
        let often = RecentMix(picks: [Self.artist], style: .shuffle,
                              plays: (1...5).map { Self.now - Double($0) * Self.day })
        let longAgo = RecentMix(picks: [Self.album], style: .play,
                                plays: (1...8).map { Self.now - 365 * Self.day - Double($0) * Self.day })
        let justNow = RecentMix(picks: [Self.playlist], style: .play, plays: [Self.now])
        let ranked = RecentMixes.ranked([longAgo, often, justNow], at: Self.now)
        #expect(ranked.map(\.id) == [justNow.id, often.id, longAgo.id])
    }

    @Test("past the limit the lowest score goes, never the one just played")
    func limit() {
        let old = (0..<RecentMixes.limit).map { index in
            RecentMix(picks: [.artist(ratingKey: "\(index)", title: "", thumb: nil)], style: .shuffle,
                      plays: Array(repeating: Self.now - Double(index) * Self.day, count: 3))
        }
        let list = RecentMixes.recording([Self.playlist], style: .play, at: Self.now, in: old)
        #expect(list.count == RecentMixes.limit)
        #expect(list.contains { $0.picks == [Self.playlist] })
        // The oldest of the old went.
        #expect(!list.contains { $0.picks.first?.ratingKey == "\(RecentMixes.limit - 1)" })
    }

    @Test("only the last plays are kept for the score, the count keeps going")
    func playLimit() {
        var list: [RecentMix] = []
        for index in 0..<(RecentMixes.playLimit + 5) {
            list = RecentMixes.recording([Self.artist], style: .shuffle, at: Self.now + Double(index), in: list)
        }
        #expect(list[0].plays.count == RecentMixes.playLimit)
        #expect(list[0].playCount == RecentMixes.playLimit + 5)
    }

    @Test("an edited mix takes its history to the new picks, merging with one already there")
    func moving() {
        var list = RecentMixes.recording([Self.artist], style: .shuffle, at: Self.now, in: [])
        list = RecentMixes.recording([Self.artist], style: .shuffle, at: Self.now + 60, in: list)
        let oldKey = RecentMix.key(for: [Self.artist])
        let moved = RecentMixes.moving(oldKey, to: [Self.artist, Self.album], in: list)
        #expect(moved.count == 1)
        #expect(moved[0].id == RecentMix.key(for: [Self.album, Self.artist]))
        #expect(moved[0].playCount == 2)

        let other = RecentMixes.recording([Self.album, Self.artist], style: .mixAlbums, at: Self.now + 30, in: list)
        let merged = RecentMixes.moving(oldKey, to: [Self.artist, Self.album], in: other)
        #expect(merged.count == 1)
        #expect(merged[0].playCount == 3)
        #expect(merged[0].plays == [Self.now, Self.now + 30, Self.now + 60])
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let list = RecentMixes.recording([Self.album, .favorites], style: .mixAlbums, at: Self.now, in: [])
        let decoded = try JSONDecoder().decode([RecentMix].self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }
}
