import Foundation
import Testing
@testable import PlexKit

@Suite("Queue snapshot")
struct QueueSnapshotTests {
    private static func track(_ key: String) -> PlexTrack {
        let json = """
        {"ratingKey":"\(key)","title":"Track \(key)","duration":200000,"parentTitle":"Album","grandparentTitle":"Artist"}
        """
        return try! JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    private static let tracks = ["1", "2", "3", "4", "5"].map(track)

    @Test("a plain queue comes back in order with its cursor")
    func plain() {
        let queue = PlayQueue(Self.tracks, startingAt: 2)
        let restored = QueueSnapshot(queue, repeatMode: .all, position: 42, savedAt: .now).queue
        #expect(restored.entries.map(\.item.ratingKey) == ["1", "2", "3", "4", "5"])
        #expect(restored.current?.ratingKey == "3")
        #expect(!restored.isShuffled)
    }

    @Test("a shuffled queue comes back shuffled and unshuffles to the original order")
    func shuffled() {
        var queue = PlayQueue(Self.tracks, startingAt: 1)
        var generator = SeededGenerator(seed: 7)
        queue.shuffle(using: &generator)
        queue.advance()
        var restored = QueueSnapshot(queue, repeatMode: .off, position: 0, savedAt: .now).queue
        #expect(restored.entries.map(\.item.ratingKey) == queue.entries.map(\.item.ratingKey))
        #expect(restored.current?.ratingKey == queue.current?.ratingKey)
        #expect(restored.isShuffled)
        restored.unshuffle()
        #expect(restored.entries.map(\.item.ratingKey) == ["1", "2", "3", "4", "5"])
        #expect(restored.current?.ratingKey == queue.current?.ratingKey)
    }

    @Test("a pre-shuffle order that doesn't cover the queue is dropped")
    func badOrder() {
        let saved = PlayQueue<PlexTrack>.Saved(items: Self.tracks, currentIndex: 0, unshuffledOrder: [0, 1, 1])
        #expect(!PlayQueue(saved).isShuffled)
    }

    @Test("the store writes and reads a snapshot per key, and removes it")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        let snapshot = QueueSnapshot(PlayQueue(Self.tracks, startingAt: 3), repeatMode: .one, position: 61.5,
                                     savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(snapshot, key: "playQueue.acct.server/3")
        #expect(store.load(key: "playQueue.acct.server/3") == snapshot)
        #expect(store.load(key: "playQueue.other") == nil)
        #expect(store.load(key: "playQueue.acct.server/3")?.repeatModeValue == .one)
        store.remove(key: "playQueue.acct.server/3")
        #expect(store.load(key: "playQueue.acct.server/3") == nil)
    }
}
