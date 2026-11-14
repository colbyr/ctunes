import Foundation

/// A mix played, remembered so it can be played again from the Music
/// screen's row without being saved first. Identity is the set of picks,
/// whatever order they were tapped in; the style is whichever it was
/// played as last. One that earns a name is pinned, which makes it a
/// `SavedMix` like any other.
public struct RecentMix: Codable, Sendable, Hashable, Identifiable {
    public var picks: [MixPick]
    public var style: PlayStyle
    /// When it was played, oldest first; only the last `RecentMixes.playLimit`.
    /// Their count is the play count shown, so it reads "50+" at the cap.
    public var plays: [Date]

    public init(picks: [MixPick], style: PlayStyle, plays: [Date]) {
        self.picks = picks
        self.style = style
        self.plays = plays
    }

    public var id: String { Self.key(for: picks) }

    /// The picks' ids sorted and joined: what makes two mixes the same.
    public static func key(for picks: [MixPick]) -> String {
        Set(picks.map(\.id)).sorted().joined(separator: ",")
    }

    public var lastPlayed: Date { plays.last ?? .distantPast }

    /// Each play counts half as much every `RecentMixes.halfLife`.
    public func score(at now: Date) -> Double {
        plays.reduce(0) { $0 + pow(0.5, max(0, now.timeIntervalSince($1)) / RecentMixes.halfLife) }
    }
}

extension SavedMix {
    /// The same key a recent mix has, so a pinned one is found among them.
    public var pickKey: String { RecentMix.key(for: picks) }
}

/// The recent mixes as they sync between devices: the mixes, and when a
/// mix was removed (or its picks moved by an edit), so a device that
/// still holds its plays doesn't bring it back. Two copies merge without
/// losing a play from either: see `RecentMixes.merged`.
public struct RecentMixHistory: Codable, Sendable, Equatable {
    public var mixes: [RecentMix]
    /// By key: every play up to then is gone; a later one brings it back.
    public var removed: [String: Date]

    public init(mixes: [RecentMix] = [], removed: [String: Date] = [:]) {
        self.mixes = mixes
        self.removed = removed
    }

    /// Reads this shape, or the bare list kept before recents synced.
    public static func decode(_ data: Data) -> RecentMixHistory? {
        let decoder = JSONDecoder()
        if let history = try? decoder.decode(RecentMixHistory.self, from: data) { return history }
        return (try? decoder.decode([RecentMix].self, from: data)).map { RecentMixHistory(mixes: $0) }
    }
}

public enum RecentMixes {
    /// How many mixes are kept; past it the lowest score goes.
    public static let limit = 20
    /// How many play dates each keeps for its score.
    public static let playLimit = 50
    public static let halfLife: TimeInterval = 30 * 24 * 60 * 60
    /// How long a removal is remembered: a device away from iCloud longer
    /// than this can bring a removed mix back.
    public static let removalLife: TimeInterval = 90 * 24 * 60 * 60

    /// The list with one more play of these picks: the existing mix moved
    /// on, now in this style and with these picks' latest titles, or a new
    /// one. Nothing picked is never remembered.
    public static func recording(_ picks: [MixPick], style: PlayStyle, at now: Date, in list: [RecentMix]) -> [RecentMix] {
        guard !picks.isEmpty else { return list }
        var list = list
        let key = RecentMix.key(for: picks)
        if let index = list.firstIndex(where: { $0.id == key }) {
            list[index].picks = picks
            list[index].style = style
            list[index].plays = Array((list[index].plays + [now]).suffix(playLimit))
        } else {
            list.append(RecentMix(picks: picks, style: style, plays: [now]))
        }
        guard list.count > limit else { return list }
        // The one just played always stays.
        let kept = list.filter { $0.id != key }
            .sorted { $0.score(at: now) > $1.score(at: now) }
            .prefix(limit - 1)
        return list.filter { $0.id == key || kept.contains($0) }
    }

    public static func recording(_ picks: [MixPick], style: PlayStyle, at now: Date, in history: RecentMixHistory) -> RecentMixHistory {
        var history = history
        history.mixes = recording(picks, style: style, at: now, in: history.mixes)
        return history
    }

    /// The list with the history of the mix under `oldKey` carried over to
    /// `picks`, as when a pinned mix's picks are edited: merged into the
    /// one already there with those picks, or moved onto them, so the old
    /// picks don't linger as a mix of their own.
    public static func moving(_ oldKey: String, to picks: [MixPick], in list: [RecentMix]) -> [RecentMix] {
        let newKey = RecentMix.key(for: picks)
        guard oldKey != newKey, let old = list.first(where: { $0.id == oldKey }) else { return list }
        var list = list.filter { $0.id != oldKey }
        if let index = list.firstIndex(where: { $0.id == newKey }) {
            list[index].plays = Array(Set(list[index].plays + old.plays).sorted().suffix(playLimit))
        } else {
            list.append(RecentMix(picks: picks, style: old.style, plays: old.plays))
        }
        return list
    }

    /// The same, and the old picks marked removed so another device's copy
    /// of them doesn't come back.
    public static func moving(_ oldKey: String, to picks: [MixPick], at now: Date, in history: RecentMixHistory) -> RecentMixHistory {
        guard oldKey != RecentMix.key(for: picks) else { return history }
        var history = history
        history.mixes = moving(oldKey, to: picks, in: history.mixes)
        history.removed[oldKey] = now
        return history
    }

    /// Removed here and, once synced, everywhere: until it is played again.
    public static func forgetting(_ key: String, at now: Date, in history: RecentMixHistory) -> RecentMixHistory {
        var history = history
        history.mixes.removeAll { $0.id == key }
        history.removed[key] = now
        return history
    }

    /// Two devices' copies as one. Every play either holds is kept (the
    /// last `playLimit`), the picks and style come from whichever copy
    /// played it last, the later removal of a key wins and drops the plays
    /// up to it, and the lowest scores go past `limit`. The same two
    /// copies merge to the same result in either order.
    public static func merged(_ a: RecentMixHistory, _ b: RecentMixHistory, at now: Date) -> RecentMixHistory {
        var removed = a.removed.merging(b.removed) { max($0, $1) }
        removed = removed.filter { now.timeIntervalSince($0.value) < removalLife }
        var byKey: [String: RecentMix] = [:]
        for mix in a.mixes + b.mixes {
            guard var held = byKey[mix.id] else {
                byKey[mix.id] = mix
                continue
            }
            let plays = Array(Set(held.plays + mix.plays).sorted().suffix(playLimit))
            if mix.lastPlayed > held.lastPlayed || (mix.lastPlayed == held.lastPlayed && mix.style.rawValue > held.style.rawValue) {
                held.picks = mix.picks
                held.style = mix.style
            }
            held.plays = plays
            byKey[mix.id] = held
        }
        var mixes = byKey.values.compactMap { mix -> RecentMix? in
            guard let cut = removed[mix.id] else { return mix }
            var mix = mix
            mix.plays = mix.plays.filter { $0 > cut }
            return mix.plays.isEmpty ? nil : mix
        }
        if mixes.count > limit {
            mixes = Array(mixes.sorted { ($0.score(at: now), $0.id) > ($1.score(at: now), $1.id) }.prefix(limit))
        }
        // One order whatever the inputs', so equal histories compare equal
        // and an unchanged merge never writes.
        return RecentMixHistory(mixes: mixes.sorted { $0.id < $1.id }, removed: removed)
    }

    /// The last one played first, so a mix lands at the front as it
    /// starts; the rest most played first, recent plays counting most.
    public static func ranked(_ list: [RecentMix], at now: Date) -> [RecentMix] {
        guard let latest = list.max(by: { $0.lastPlayed < $1.lastPlayed }) else { return [] }
        let rest = list.filter { $0.id != latest.id }
            .sorted { $0.score(at: now) > $1.score(at: now) }
        return [latest] + rest
    }
}
