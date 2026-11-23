import Foundation

/// The play queue as it stood when it was last saved, so a cold launch
/// can offer to pick up where it left off: the tracks in play order, the
/// cursor, the pre-shuffle order, the repeat mode and how far into the
/// current track. Saved per account and library (the tracks are that
/// library's), on the device only.
public struct QueueSnapshot: Codable, Sendable, Equatable {
    public var tracks: [PlexTrack]
    public var currentIndex: Int
    /// Positions into `tracks` in their order before shuffling; nil when
    /// the queue isn't shuffled.
    public var unshuffledOrder: [Int]?
    /// `RepeatMode`'s raw value.
    public var repeatMode: String
    /// Seconds into the current track.
    public var position: Double
    public var savedAt: Date

    public init(
        tracks: [PlexTrack], currentIndex: Int, unshuffledOrder: [Int]?,
        repeatMode: RepeatMode, position: Double, savedAt: Date
    ) {
        self.tracks = tracks
        self.currentIndex = currentIndex
        self.unshuffledOrder = unshuffledOrder
        self.repeatMode = repeatMode.rawValue
        self.position = position
        self.savedAt = savedAt
    }

    public init(_ queue: PlayQueue<PlexTrack>, repeatMode: RepeatMode, position: Double, savedAt: Date) {
        let saved = queue.saved
        self.init(tracks: saved.items, currentIndex: saved.currentIndex, unshuffledOrder: saved.unshuffledOrder,
                  repeatMode: repeatMode, position: position, savedAt: savedAt)
    }

    /// The queue it describes, shuffled as it was.
    public var queue: PlayQueue<PlexTrack> {
        PlayQueue(.init(items: tracks, currentIndex: currentIndex, unshuffledOrder: unshuffledOrder))
    }

    public var repeatModeValue: RepeatMode { RepeatMode(rawValue: repeatMode) ?? .off }

    public var current: PlexTrack? {
        tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil
    }
}

/// One snapshot file per key under a directory. Writes are atomic, so a
/// process killed mid-write leaves the last good copy.
public struct QueueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func file(for key: String) -> URL {
        let name = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "\(name).json")
    }

    public func load(key: String) -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    public func save(_ snapshot: QueueSnapshot, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file(for: key), options: .atomic)
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: file(for: key))
    }
}
