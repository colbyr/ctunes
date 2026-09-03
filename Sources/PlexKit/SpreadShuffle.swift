import Foundation

extension Array {
    /// Spotify-style balanced shuffle, after Poláček's 2014 "How to shuffle
    /// songs?" (building on Fiedler's balanced shuffle).
    ///
    /// Items sharing the first key are spread evenly across the unit interval
    /// with a random offset and ±10% jitter, so a group of n lands roughly
    /// every 1/n of the result instead of clumping the way a uniform shuffle
    /// does. Within a group the remaining keys recurse; with no keys left the
    /// group is shuffled uniformly. The result is the sort by position.
    public func spreadShuffled(
        by keys: [@Sendable (Element) -> String],
        using generator: inout some RandomNumberGenerator
    ) -> [Element] {
        guard let key = keys.first else { return shuffled(using: &generator) }

        // Group in first-seen order so a seeded generator gives one answer.
        var order: [String] = []
        var groups: [String: [Element]] = [:]
        for item in self {
            let k = key(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }

        var placed: [(position: Double, item: Element)] = []
        placed.reserveCapacity(count)
        for k in order {
            let inner = groups[k]!.spreadShuffled(by: [@Sendable (Element) -> String](keys.dropFirst()), using: &generator)
            let spacing = 1 / Double(inner.count)
            let offset = Double.random(in: 0..<spacing, using: &generator)
            for (i, item) in inner.enumerated() {
                let jitter = Double.random(in: -0.1...0.1, using: &generator) * spacing
                placed.append((offset + Double(i) * spacing + jitter, item))
            }
        }
        return placed.sorted { $0.position < $1.position }.map(\.item)
    }

    public func spreadShuffled(by keys: [@Sendable (Element) -> String]) -> [Element] {
        var generator = SystemRandomNumberGenerator()
        return spreadShuffled(by: keys, using: &generator)
    }
}

extension Array {
    /// Whole-album shuffle. Groups by `album` in first-seen order, keeps each
    /// group's internal order, spread-shuffles the albums by `artist` so one
    /// artist's records don't run back to back, and flattens.
    public func albumShuffled(
        album: @escaping @Sendable (Element) -> String,
        artist: @escaping @Sendable (Element) -> String,
        using generator: inout some RandomNumberGenerator
    ) -> [Element] {
        var order: [String] = []
        var groups: [String: [Element]] = [:]
        for item in self {
            let k = album(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        let albums = order.map { groups[$0]! }
        return albums
            .spreadShuffled(by: [{ artist($0[0]) }], using: &generator)
            .flatMap { $0 }
    }

    public func albumShuffled(
        album: @escaping @Sendable (Element) -> String,
        artist: @escaping @Sendable (Element) -> String
    ) -> [Element] {
        var generator = SystemRandomNumberGenerator()
        return albumShuffled(album: album, artist: artist, using: &generator)
    }
}
