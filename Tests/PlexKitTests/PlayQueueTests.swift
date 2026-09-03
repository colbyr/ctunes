import Foundation
import Testing
@testable import PlexKit

@Suite("Play queue")
struct PlayQueueTests {
    private func queue() -> PlayQueue<String> {
        PlayQueue(["a", "b", "c", "d"], startingAt: 1)
    }

    private func items(_ q: PlayQueue<String>) -> [String] { q.entries.map(\.item) }

    @Test("empty queue has no current item and every move is a no-op")
    func empty() {
        var q = PlayQueue<String>()
        #expect(q.current == nil)
        #expect(q.upcoming.isEmpty)
        let moved = [q.advance(), q.retreat(), q.remove(at: 0), q.jump(to: 0)]
        #expect(moved == [false, false, false, false])
    }

    @Test("start index is clamped into range")
    func clamps() {
        #expect(PlayQueue(["a", "b"], startingAt: -3).currentIndex == 0)
        #expect(PlayQueue(["a", "b"], startingAt: 9).currentIndex == 1)
        #expect(PlayQueue([String](), startingAt: 5).currentIndex == 0)
    }

    @Test("advance and retreat stop at the ends")
    func stepping() {
        var q = queue()
        let forward = [q.advance(), q.advance(), q.advance()]
        #expect(forward == [true, true, false])
        #expect(q.current == "d")

        let back = [q.retreat(), q.retreat(), q.retreat(), q.retreat()]
        #expect(back == [true, true, true, false])
        #expect(q.current == "a")
    }

    @Test("play next inserts after current, append goes to the end")
    func inserting() {
        var q = queue()
        q.playNext(["x", "y"])
        q.append(["z"])
        #expect(items(q) == ["a", "b", "x", "y", "c", "d", "z"])
        #expect(q.current == "b")
        #expect(q.upcoming.map(\.item) == ["x", "y", "c", "d", "z"])
    }

    @Test("inserting into an empty queue makes the first item current")
    func insertingIntoEmpty() {
        var next = PlayQueue<String>()
        next.playNext(["x", "y"])
        #expect(next.current == "x")
        #expect(next.upcoming.map(\.item) == ["y"])

        var appended = PlayQueue<String>()
        appended.append(["x", "y"])
        #expect(appended.current == "x")
    }

    @Test("removing before current shifts the index without changing the item")
    func removeBefore() {
        var q = queue()
        let changed = q.remove(at: 0)
        #expect(!changed)
        #expect(q.currentIndex == 0)
        #expect(q.current == "b")
    }

    @Test("removing after current leaves it alone")
    func removeAfter() {
        var q = queue()
        let changed = q.remove(at: 3)
        #expect(!changed)
        #expect(q.current == "b")
        #expect(q.upcoming.map(\.item) == ["c"])
    }

    @Test("removing the current item promotes the next one")
    func removeCurrent() {
        var q = queue()
        let changed = q.remove(at: 1)
        #expect(changed)
        #expect(q.current == "c")
        #expect(q.currentIndex == 1)
    }

    @Test("removing the current item at the end falls back to the previous one")
    func removeCurrentAtEnd() {
        var q = PlayQueue(["a", "b"], startingAt: 1)
        let changed = q.remove(at: 1)
        #expect(changed)
        #expect(q.current == "a")

        var sole = PlayQueue(["a"], startingAt: 0)
        let emptied = sole.remove(at: 0)
        #expect(emptied)
        #expect(sole.current == nil)
        #expect(sole.upcoming.isEmpty)
    }

    @Test("jump ignores out-of-range and same-index targets")
    func jump() {
        var q = queue()
        let results = [q.jump(to: 4), q.jump(to: -1), q.jump(to: 1), q.jump(to: 3)]
        #expect(results == [false, false, false, true])
        #expect(q.current == "d")
    }

    @Test("advance wraps to the start only when asked")
    func wrapping() {
        var q = PlayQueue(["a", "b"], startingAt: 1)
        let stopped = q.advance()
        #expect(!stopped)
        #expect(q.current == "b")
        let wrapped = q.advance(wrapping: true)
        #expect(wrapped)
        #expect(q.current == "a")

        var empty = PlayQueue<String>()
        let moved = empty.advance(wrapping: true)
        #expect(!moved)
    }

    @Test("shuffle keeps the current item first and unshuffle restores the order")
    func shuffleRoundTrip() {
        var q = PlayQueue(["a", "b", "c", "d", "e"], startingAt: 2)
        var rng = SeededGenerator(seed: 7)
        q.shuffle(using: &rng)
        #expect(q.isShuffled)
        #expect(q.current == "c")
        #expect(q.currentIndex == 0)
        #expect(Set(items(q)) == ["a", "b", "c", "d", "e"])
        #expect(q.upcoming.count == 4)

        q.unshuffle()
        #expect(!q.isShuffled)
        #expect(items(q) == ["a", "b", "c", "d", "e"])
        #expect(q.current == "c")
        #expect(q.currentIndex == 2)
    }

    @Test("reshuffling shuffles against the original order, not the shuffled one")
    func reshuffle() {
        var q = PlayQueue(["a", "b", "c", "d"], startingAt: 0)
        var rng = SeededGenerator(seed: 1)
        q.shuffle(using: &rng)
        _ = q.advance()
        let moved = q.current
        q.shuffle(using: &rng)
        #expect(q.current == moved)
        q.unshuffle()
        #expect(items(q) == ["a", "b", "c", "d"])
        #expect(q.current == moved)
    }

    @Test("edits made while shuffled survive unshuffle")
    func shuffleThenEdit() {
        var q = PlayQueue(["a", "b", "c", "d"], startingAt: 1)
        var rng = SeededGenerator(seed: 3)
        q.shuffle(using: &rng)
        // Drop "d", play "x" next, append "y".
        let d = try! #require(q.entries.first { $0.item == "d" })
        q.remove(at: q.index(of: d.id)!)
        q.playNext(["x"])
        q.append(["y"])
        q.unshuffle()
        #expect(q.current == "b")
        #expect(items(q) == ["a", "b", "x", "y", "c"])
    }

    @Test("shuffling an empty queue is a no-op")
    func shuffleEmpty() {
        var q = PlayQueue<String>()
        q.shuffle()
        #expect(!q.isShuffled)
        q.unshuffle()
        #expect(q.isEmpty)
    }

    @Test("repeat mode cycles off, all, one")
    func repeatCycle() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }

    @Test("duplicate items get distinct, stable ids")
    func duplicates() {
        var q = PlayQueue(["a", "a", "a"], startingAt: 0)
        let ids = q.entries.map(\.id)
        #expect(Set(ids).count == 3)
        q.remove(at: 2)
        #expect(q.entries.map(\.id) == Array(ids.prefix(2)))
        q.append(["a"])
        let newest = try! #require(q.entries.last).id
        #expect(!ids.contains(newest))
    }

    @Test("real tracks can be queued twice over")
    func tracksFixture() throws {
        let tracks = try JSONDecoder()
            .decode(MediaContainerResponse<PlexTrack>.self, from: Fixture.data("tracks"))
            .items
        var q = PlayQueue(tracks, startingAt: 0)
        q.append(tracks)
        #expect(q.upcoming.count == 13)
        #expect(Set(q.upcoming.map(\.id)).count == 13)
        let last = try #require(q.upcoming.last)
        #expect(q.index(of: last.id) == 13)
    }
}
