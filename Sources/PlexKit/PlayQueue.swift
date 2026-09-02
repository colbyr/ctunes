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

    /// False, and unchanged, at the last item.
    public mutating func advance() -> Bool {
        guard currentIndex + 1 < entries.count else { return false }
        currentIndex += 1
        return true
    }

    /// False, and unchanged, at the first item.
    public mutating func retreat() -> Bool {
        guard currentIndex > 0, !entries.isEmpty else { return false }
        currentIndex -= 1
        return true
    }

    private mutating func makeEntries(_ items: [Item]) -> [Entry] {
        defer { nextID += items.count }
        return items.enumerated().map { Entry(id: nextID + $0.offset, item: $0.element) }
    }
}
