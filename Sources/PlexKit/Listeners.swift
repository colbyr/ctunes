import Foundation

/// Someone who rides along with the library owner and has artists they'd
/// rather not hear. Lives on the phone, not in Plex, so no account is needed.
public struct Listener: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    /// Index into a palette the app owns; kept as a number so the package
    /// stays free of UI types.
    public var colorIndex: Int
    /// Artist ratingKeys this listener has vetoed.
    public var vetoedArtistKeys: Set<String>

    public init(
        id: UUID = UUID(),
        name: String,
        colorIndex: Int = 0,
        vetoedArtistKeys: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.vetoedArtistKeys = vetoedArtistKeys
    }

    public var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// Every listener plus the set currently in the car. The owner is implicit and
/// always listening, so what's hidden is just the union of the active
/// listeners' vetoes.
public struct ListenerRoster: Codable, Sendable, Equatable {
    public var listeners: [Listener] = []
    public var activeIDs: Set<UUID> = []

    public init(listeners: [Listener] = [], activeIDs: Set<UUID> = []) {
        self.listeners = listeners
        self.activeIDs = activeIDs.intersection(listeners.map(\.id))
    }

    /// Active listeners in roster order.
    public var active: [Listener] {
        listeners.filter { activeIDs.contains($0.id) }
    }

    public var hiddenArtistKeys: Set<String> {
        active.reduce(into: Set<String>()) { $0.formUnion($1.vetoedArtistKeys) }
    }

    public func hides(_ artistKey: String) -> Bool {
        active.contains { $0.vetoedArtistKeys.contains(artistKey) }
    }

    /// Everyone who vetoed the artist, listening or not.
    public func vetoers(of artistKey: String) -> [Listener] {
        listeners.filter { $0.vetoedArtistKeys.contains(artistKey) }
    }

    public func listener(_ id: UUID) -> Listener? {
        listeners.first { $0.id == id }
    }

    public func isActive(_ id: UUID) -> Bool { activeIDs.contains(id) }

    @discardableResult
    public mutating func add(name: String, paletteSize: Int) -> Listener {
        let listener = Listener(
            name: name,
            colorIndex: paletteSize > 0 ? listeners.count % paletteSize : 0
        )
        listeners.append(listener)
        return listener
    }

    public mutating func remove(_ id: UUID) {
        listeners.removeAll { $0.id == id }
        activeIDs.remove(id)
    }

    public mutating func toggleActive(_ id: UUID) {
        guard listener(id) != nil else { return }
        if activeIDs.contains(id) { activeIDs.remove(id) } else { activeIDs.insert(id) }
    }

    public mutating func toggleVeto(artistKey: String, for id: UUID) {
        update(id) {
            if $0.vetoedArtistKeys.contains(artistKey) {
                $0.vetoedArtistKeys.remove(artistKey)
            } else {
                $0.vetoedArtistKeys.insert(artistKey)
            }
        }
    }

    public mutating func update(_ id: UUID, _ change: (inout Listener) -> Void) {
        guard let index = listeners.firstIndex(where: { $0.id == id }) else { return }
        change(&listeners[index])
    }

    /// "Laura", "Laura & Kids", "Laura, Kids & Sam".
    public static func joinNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
    }
}
