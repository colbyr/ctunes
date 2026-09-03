import Foundation
import Testing
@testable import PlexKit

@Suite("Spread shuffle")
struct SpreadShuffleTests {
    private struct Track: Equatable, Hashable {
        let artist: String
        let album: String
        let n: Int
    }

    private static let grouping: [@Sendable (Track) -> String] = [{ $0.artist }, { $0.album }]

    private func tracks(artists: [String: Int]) -> [Track] {
        artists.sorted { $0.key < $1.key }.flatMap { artist, count in
            (0..<count).map { Track(artist: artist, album: "\(artist)-1", n: $0) }
        }
    }

    /// Length of the longest run of equal values.
    private func longestRun(_ values: [String]) -> Int {
        var best = 0, run = 0, last: String?
        for v in values {
            run = v == last ? run + 1 : 1
            last = v
            best = max(best, run)
        }
        return best
    }

    @Test("keeps every track and is deterministic for a seed")
    func multiset() {
        let input = tracks(artists: ["a": 5, "b": 3, "c": 7])
        var rng1 = SeededGenerator(seed: 4)
        var rng2 = SeededGenerator(seed: 4)
        let out1 = input.spreadShuffled(by: Self.grouping, using: &rng1)
        let out2 = input.spreadShuffled(by: Self.grouping, using: &rng2)
        #expect(out1 == out2)
        #expect(out1.count == input.count)
        #expect(Set(out1) == Set(input))
    }

    @Test("three equal artists interleave with no long runs", arguments: 0..<20)
    func evenArtists(seed: UInt64) {
        let input = tracks(artists: ["a": 10, "b": 10, "c": 10])
        var rng = SeededGenerator(seed: seed)
        let artists = input.spreadShuffled(by: Self.grouping, using: &rng).map(\.artist)
        #expect(longestRun(artists) <= 2)
        for third in stride(from: 0, to: 30, by: 10) {
            #expect(Set(artists[third..<third + 10]) == ["a", "b", "c"])
        }
    }

    @Test("rare tracks land in different halves", arguments: 0..<20)
    func unequal(seed: UInt64) {
        let input = tracks(artists: ["big": 20, "rare": 2])
        var rng = SeededGenerator(seed: seed)
        let artists = input.spreadShuffled(by: Self.grouping, using: &rng).map(\.artist)
        let positions = artists.indices.filter { artists[$0] == "rare" }
        #expect(positions.count == 2)
        #expect(positions[0] < 11 && positions[1] >= 11)
    }

    @Test("one artist spreads by album", arguments: 0..<20)
    func albums(seed: UInt64) {
        let input = ["x", "y", "z"].flatMap { album in
            (0..<4).map { Track(artist: "a", album: album, n: $0) }
        }
        var rng = SeededGenerator(seed: seed)
        let albums = input.spreadShuffled(by: Self.grouping, using: &rng).map(\.album)
        #expect(longestRun(albums) <= 2)
    }

    @Test("no keys is a uniform shuffle")
    func noKeys() {
        let input = tracks(artists: ["a": 6, "b": 6])
        var rng = SeededGenerator(seed: 9)
        let out = input.spreadShuffled(by: [], using: &rng)
        #expect(out.count == input.count)
        #expect(Set(out) == Set(input))
        var rng2 = SeededGenerator(seed: 9)
        #expect(out == input.shuffled(using: &rng2))
    }

    @Test("queue shuffle keeps the current item first and round-trips")
    func queue() {
        let input = tracks(artists: ["a": 4, "b": 4])
        var q = PlayQueue(input, startingAt: 5)
        let current = q.current
        var rng = SeededGenerator(seed: 2)
        q.shuffle(groupedBy: Self.grouping, using: &rng)
        #expect(q.isShuffled)
        #expect(q.currentIndex == 0)
        #expect(q.current == current)
        #expect(Set(q.entries.map(\.item)) == Set(input))
        #expect(longestRun(q.entries.dropFirst().map(\.item.artist)) <= 2)

        q.unshuffle()
        #expect(q.entries.map(\.item) == input)
        #expect(q.current == current)
        #expect(q.currentIndex == 5)
    }
}
