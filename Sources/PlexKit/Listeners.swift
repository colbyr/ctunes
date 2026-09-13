import Foundation

/// What a veto points at. An artist covers every album and track of
/// theirs, an album every track on it; a track is just the track.
public enum VetoTarget: Hashable, Sendable {
    case artist(String)
    case album(String)
    case track(String)

    public var kind: VetoKind {
        switch self {
        case .artist: .artist
        case .album: .album
        case .track: .track
        }
    }

    public var key: String {
        switch self {
        case .artist(let key), .album(let key), .track(let key): key
        }
    }
}

public enum VetoKind: String, Codable, Sendable, CaseIterable {
    case artist, album, track
}

/// One thing a listener would rather not hear. The title and subtitle
/// are kept with the key so the listener's page can name a track or an
/// album without a fetch, on any device the roster syncs to; identity is
/// the target alone.
public struct Veto: Codable, Sendable, Hashable, Identifiable {
    public let target: VetoTarget
    public var title: String
    public var subtitle: String?

    public var id: VetoTarget { target }
    public var kind: VetoKind { target.kind }

    public init(_ target: VetoTarget, title: String, subtitle: String? = nil) {
        self.target = target
        self.title = title
        self.subtitle = subtitle
    }

    public init(artistKey: String, title: String) {
        self.init(.artist(artistKey), title: title)
    }

    public init(album: PlexAlbum) {
        self.init(.album(album.ratingKey), title: album.title, subtitle: album.parentTitle)
    }

    /// "Karma Police" under "Radiohead · OK Computer".
    public init(track: PlexTrack) {
        let parts = [track.grandparentTitle, track.parentTitle].compactMap { $0 }
        self.init(.track(track.ratingKey), title: track.title,
                  subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    enum CodingKeys: String, CodingKey { case kind, key, title, subtitle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(VetoKind.self, forKey: .kind)
        let key = try c.decode(String.self, forKey: .key)
        let target: VetoTarget = switch kind {
        case .artist: .artist(key)
        case .album: .album(key)
        case .track: .track(key)
        }
        self.init(target, title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                  subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(target.key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
    }
}

/// An item and the wider vetoes that would cover it: an album under its
/// artist, a track under its album and artist. The header avatars and
/// the Listeners submenu take one of these so every screen answers "is
/// this hidden, and by what" the same way.
public struct VetoScope: Sendable, Hashable {
    public let veto: Veto
    /// Narrowest first: a track's album, then its artist.
    public let wider: [Veto]

    public init(artistKey: String, title: String) {
        veto = Veto(artistKey: artistKey, title: title)
        wider = []
    }

    public init(album: PlexAlbum) {
        veto = Veto(album: album)
        wider = album.parentRatingKey.map { [Veto(artistKey: $0, title: album.parentTitle ?? "")] } ?? []
    }

    public init(track: PlexTrack) {
        veto = Veto(track: track)
        var wider: [Veto] = []
        if let album = track.parentRatingKey {
            wider.append(Veto(.album(album), title: track.parentTitle ?? "", subtitle: track.grandparentTitle))
        }
        if let artist = track.grandparentRatingKey {
            wider.append(Veto(artistKey: artist, title: track.grandparentTitle ?? ""))
        }
        self.wider = wider
    }

    /// The widest of this listener's vetoes that covers the item but
    /// isn't the item's own; nil when only the item itself decides.
    public func covering(_ listener: Listener) -> Veto? {
        wider.last { listener.vetoes($0.target) }
    }
}

/// Someone who rides along with the library owner and has artists,
/// albums or tracks they'd rather not hear. Lives in the owner's iCloud
/// key-value store, not in Plex, so no account is needed and every device
/// on the same Apple ID sees the same people.
public struct Listener: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    /// Index into a palette the app owns; kept as a number so the package
    /// stays free of UI types.
    public var colorIndex: Int
    /// In the order they were added; each target at most once.
    public var vetoes: [Veto]

    public init(
        id: UUID = UUID(),
        name: String,
        colorIndex: Int = 0,
        vetoes: [Veto] = []
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.vetoes = vetoes
    }

    public var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    public func vetoes(_ target: VetoTarget) -> Bool {
        vetoes.contains { $0.target == target }
    }

    public func vetoes(of kind: VetoKind) -> [Veto] {
        vetoes.filter { $0.kind == kind }
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

    // A roster written before albums and tracks could be vetoed holds
    // `vetoedArtistKeys` alone; those become artist vetoes with no title,
    // which the listener's page names from the library. The old key is
    // still written so a device on an older build keeps the artist vetoes
    // it understands.
    enum CodingKeys: String, CodingKey { case id, name, colorIndex, vetoes, vetoedArtistKeys }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let vetoes = try c.decodeIfPresent([Veto].self, forKey: .vetoes)
            ?? (try c.decodeIfPresent(Set<String>.self, forKey: .vetoedArtistKeys) ?? [])
                .sorted().map { Veto(artistKey: $0, title: "") }
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            colorIndex: try c.decode(Int.self, forKey: .colorIndex),
            vetoes: vetoes
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encode(vetoes, forKey: .vetoes)
        try c.encode(Set(vetoes(of: .artist).map(\.target.key)), forKey: .vetoedArtistKeys)
    }
}

/// The active listeners' vetoes as keys, one set per kind. An album is
/// hidden by its own veto or its artist's; a track by its own, its
/// album's or its artist's. `within:` narrows that to what a collection
/// being played should skip: inside an album only the track's own veto
/// counts, inside an artist the track's and its album's, since the
/// collection itself was opened on purpose.
public struct VetoSet: Equatable, Sendable {
    public var artists: Set<String> = []
    public var albums: Set<String> = []
    public var tracks: Set<String> = []

    public init(artists: Set<String> = [], albums: Set<String> = [], tracks: Set<String> = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }

    public func contains(_ target: VetoTarget) -> Bool {
        switch target {
        case .artist(let key): artists.contains(key)
        case .album(let key): albums.contains(key)
        case .track(let key): tracks.contains(key)
        }
    }

    public mutating func insert(_ target: VetoTarget) {
        switch target {
        case .artist(let key): artists.insert(key)
        case .album(let key): albums.insert(key)
        case .track(let key): tracks.insert(key)
        }
    }

    public func hides(_ album: PlexAlbum, within container: VetoKind? = nil) -> Bool {
        albums.contains(album.ratingKey) || (container == nil && artists.contains(album.artistKey))
    }

    public func hides(_ track: PlexTrack, within container: VetoKind? = nil) -> Bool {
        switch container {
        case .track:
            return false
        case .album:
            return tracks.contains(track.ratingKey)
        case .artist:
            return tracks.contains(track.ratingKey) || albums.contains(track.parentRatingKey ?? "")
        case nil:
            return tracks.contains(track.ratingKey) || albums.contains(track.parentRatingKey ?? "")
                || artists.contains(track.grandparentRatingKey ?? "")
        }
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

    /// The union of the active listeners' vetoes.
    public var hidden: VetoSet {
        var set = VetoSet()
        for listener in active {
            for veto in listener.vetoes { set.insert(veto.target) }
        }
        return set
    }

    public func hides(_ target: VetoTarget) -> Bool {
        active.contains { $0.vetoes(target) }
    }

    /// Everyone who vetoed the target, listening or not.
    public func vetoers(of target: VetoTarget) -> [Listener] {
        listeners.filter { $0.vetoes(target) }
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

    /// Adds the veto, or removes the one already on the same target.
    /// Vetoes never absorb each other: an artist veto beside an album
    /// veto leaves the album hidden when the artist is allowed again.
    public mutating func toggleVeto(_ veto: Veto, for id: UUID) {
        update(id) {
            if let index = $0.vetoes.firstIndex(where: { $0.target == veto.target }) {
                $0.vetoes.remove(at: index)
            } else {
                $0.vetoes.append(veto)
            }
        }
    }

    public mutating func removeVeto(_ target: VetoTarget, for id: UUID) {
        update(id) { $0.vetoes.removeAll { $0.target == target } }
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
