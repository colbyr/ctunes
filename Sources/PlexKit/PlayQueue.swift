import Foundation

/// An ordered list of items with a cursor on the one currently playing.
///
/// A pure value type so the index bookkeeping is testable without a player.
/// Each entry carries an id assigned at insertion and never reused, so the same
/// item can appear twice and still be addressed unambiguously.
public struct PlayQueue<Item: Sendable>: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let item: Item
    }

    public private(set) var entries: [Entry] = []
    /// Meaningless while the queue is empty.
    public private(set) var currentIndex = 0
    private var nextID = 0

    /// The pre-shuffle order, kept so shuffle can be undone. Entries added or
    /// removed while shuffled are reconciled against it on restore.
    private var unshuffled: [Entry]?

    public var isShuffled: Bool { unshuffled != nil }

    public init() {}

    public init(_ items: [Item], startingAt index: Int) {
        entries = makeEntries(items)
        currentIndex = entries.isEmpty ? 0 : min(max(index, 0), entries.count - 1)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var currentEntry: Entry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    public var current: Item? { currentEntry?.item }

    /// Everything after the current item.
    public var upcoming: ArraySlice<Entry> {
        guard !entries.isEmpty else { return [] }
        return entries[(currentIndex + 1)...]
    }

    public func index(of id: Entry.ID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// Inserts directly after the current item, preserving order.
    public mutating func playNext(_ items: [Item]) {
        let at = entries.isEmpty ? 0 : currentIndex + 1
        entries.insert(contentsOf: makeEntries(items), at: at)
    }

    public mutating func append(_ items: [Item]) {
        entries.append(contentsOf: makeEntries(items))
    }

    /// Returns true when the current item changed and the caller must reload.
    @discardableResult
    public mutating func remove(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        entries.remove(at: index)

        if index < currentIndex {
            currentIndex -= 1
            return false
        }
        if index > currentIndex {
            return false
        }
        // Removed the current item: the former next takes its place, or the
        // former previous when there is no next.
        currentIndex = min(currentIndex, max(0, entries.count - 1))
        return true
    }

    /// Out of range is a no-op. Returns true when the current item changed.
    @discardableResult
    public mutating func jump(to index: Int) -> Bool {
        guard entries.indices.contains(index), index != currentIndex else { return false }
        currentIndex = index
        return true
    }

    /// False, and unchanged, at the last item unless `wrapping`, which loops
    /// back to the first.
    public mutating func advance(wrapping: Bool = false) -> Bool {
        guard !entries.isEmpty else { return false }
        if currentIndex + 1 < entries.count {
            currentIndex += 1
            return true
        }
        guard wrapping else { return false }
        currentIndex = 0
        return true
    }

    /// False, and unchanged, at the first item.
    public mutating func retreat() -> Bool {
        guard currentIndex > 0, !entries.isEmpty else { return false }
        currentIndex -= 1
        return true
    }

    // MARK: - Shuffle

    /// Keeps the current item where the listener is, moves it to the front
    /// and shuffles everything else behind it, Apple Music style. Shuffling an
    /// already shuffled queue reshuffles against the original order.
    public mutating func shuffle(using generator: inout some RandomNumberGenerator) {
        guard !entries.isEmpty else { return }
        let original = unshuffled ?? entries
        unshuffled = original
        guard let current = currentEntry else { return }
        var rest = original.filter { $0.id != current.id }
        rest.shuffle(using: &generator)
        entries = [current] + rest
        currentIndex = 0
    }

    public mutating func shuffle() {
        var generator = SystemRandomNumberGenerator()
        shuffle(using: &generator)
    }

    /// Restores the order from before `shuffle`. Items removed meanwhile stay
    /// removed; items added meanwhile keep their place relative to the current
    /// item, since that is the only order they were ever seen in.
    public mutating func unshuffle() {
        guard let original = unshuffled else { return }
        unshuffled = nil
        let currentID = currentEntry?.id
        let present = Set(entries.map(\.id))
        let known = Set(original.map(\.id))
        var restored = original.filter { present.contains($0.id) }
        let added = entries.filter { !known.contains($0.id) }
        if let currentID, let at = restored.firstIndex(where: { $0.id == currentID }) {
            restored.insert(contentsOf: added, at: at + 1)
        } else {
            restored.append(contentsOf: added)
        }
        entries = restored
        currentIndex = currentID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
    }

    private mutating func makeEntries(_ items: [Item]) -> [Entry] {
        defer { nextID += items.count }
        return items.enumerated().map { Entry(id: nextID + $0.offset, item: $0.element) }
    }
}

/// How playback continues once the current item ends.
public enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one

    /// Cycles off → all → one → off, the order the button steps through.
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
