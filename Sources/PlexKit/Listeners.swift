import Foundation

/// Someone who rides along with the library owner and has artists they'd
/// rather not hear. Lives in the owner's iCloud key-value store, not in
/// Plex, so no account is needed and every device on the same Apple ID
/// sees the same people.
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

    /// The library owner's fixed id, so every device agrees on which entry
    /// is them and their vetoes sync like anyone else's.
    public static let ownerID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let ownerName = "You"

    public var isOwner: Bool { id == Self.ownerID }

    /// The owner as a fresh entry: no vetoes, the palette's last slot (amber).
    static func owner(paletteSize: Int = 6) -> Listener {
        Listener(id: ownerID, name: ownerName, colorIndex: max(paletteSize - 1, 0))
    }
}

/// Every listener plus the set currently in the car. The owner is a listener
/// like the others, always first under `Listener.ownerID`: they toggle and
/// veto the same way, so what's hidden is just the union of the active
/// listeners' vetoes. The listeners sync across devices; who is listening is
/// per device, since the phone in the car and the Mac at home differ.
public struct ListenerRoster: Codable, Sendable, Equatable {
    public private(set) var listeners: [Listener] = []
    public private(set) var activeIDs: Set<UUID> = []

    /// A roster from before the owner was an entry gains one, listening,
    /// so nothing changes for them until they say so.
    public init(listeners: [Listener] = [], activeIDs: Set<UUID> = []) {
        var listeners = listeners
        var activeIDs = activeIDs.intersection(listeners.map(\.id))
        if !listeners.contains(where: \.isOwner) {
            listeners.insert(.owner(), at: 0)
            activeIDs.insert(Listener.ownerID)
        }
        self.listeners = listeners
        self.activeIDs = activeIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            listeners: try c.decode([Listener].self, forKey: .listeners),
            activeIDs: try c.decode(Set<UUID>.self, forKey: .activeIDs)
        )
    }

    public var owner: Listener { listeners.first { $0.isOwner } ?? .owner() }

    /// Everyone but the owner, for the places that list who else rides along.
    public var others: [Listener] { listeners.filter { !$0.isOwner } }

    /// The active listeners' names as they read mid-sentence: "you & Laura",
    /// so a line never says "hidden for You".
    public var activeNames: [String] {
        active.map { $0.isOwner ? "you" : $0.name }
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

    /// The owner can't be removed; they stop listening instead.
    public mutating func remove(_ id: UUID) {
        guard id != Listener.ownerID else { return }
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

    /// Adopts another device's listeners wholesale, keeping only the active
    /// picks that still name someone. Last writer wins; there is no per-field
    /// merge, which is fine for a list this small. A list from a device that
    /// predates the owner entry keeps this device's owner, vetoes and all.
    public mutating func replaceListeners(with listeners: [Listener]) {
        var listeners = listeners
        if !listeners.contains(where: \.isOwner) {
            listeners.insert(owner, at: 0)
        }
        self.listeners = listeners
        activeIDs = activeIDs.intersection(listeners.map(\.id))
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
