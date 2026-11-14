import Foundation

/// A mix played from Quick Mix, remembered on this device so it can be
/// played again from the Recent row without being saved first. Identity
/// is the set of picks, whatever order they were tapped in; the style is
/// whichever it was played as last. One that earns a name is pinned,
/// which makes it a `SavedMix` like any other.
public struct RecentMix: Codable, Sendable, Hashable, Identifiable {
    public var picks: [MixPick]
    public var style: PlayStyle
    /// When it was played, oldest first; only the last `RecentMixes.playLimit`.
    public var plays: [Date]
    /// Every play, past the ones kept for ranking.
    public var playCount: Int

    public init(picks: [MixPick], style: PlayStyle, plays: [Date], playCount: Int? = nil) {
        self.picks = picks
        self.style = style
        self.plays = plays
        self.playCount = playCount ?? plays.count
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

public enum RecentMixes {
    /// How many mixes are kept; past it the lowest score goes.
    public static let limit = 20
    /// How many play dates each keeps for its score.
    public static let playLimit = 50
    public static let halfLife: TimeInterval = 30 * 24 * 60 * 60

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
            list[index].playCount += 1
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

    /// The list with the history of the mix under `oldKey` carried over to
    /// `picks`, as when a pinned mix's picks are edited: merged into the
    /// one already there with those picks, or moved onto them, so the old
    /// picks don't linger as a mix of their own.
    public static func moving(_ oldKey: String, to picks: [MixPick], in list: [RecentMix]) -> [RecentMix] {
        let newKey = RecentMix.key(for: picks)
        guard oldKey != newKey, let old = list.first(where: { $0.id == oldKey }) else { return list }
        var list = list.filter { $0.id != oldKey }
        if let index = list.firstIndex(where: { $0.id == newKey }) {
            list[index].plays = Array((list[index].plays + old.plays).sorted().suffix(playLimit))
            list[index].playCount += old.playCount
        } else {
            list.append(RecentMix(picks: picks, style: old.style, plays: old.plays, playCount: old.playCount))
        }
        return list
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
