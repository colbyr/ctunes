#if DEBUG
import AppIntents
import Foundation
import MediaIntents
import os

/// `CTUNES_DEV_INTENT` runs one of the intents a moment after launch and
/// logs the outcome under category `Siri`, so a simulator run shows the
/// whole path without Siri: `favorites`, `rotation`, `resume`,
/// `playlist:<name>` or `shuffle:<name>` for the App Shortcuts (the name
/// matched the way the entity query matches what Siri heard);
/// `search:<query>` logs what the value query would hand Siri for it,
/// `play:<query>` plays its best hit through `PlayAudioIntent` (Siri's
/// pick, in effect), `playshuffle:<query>` shuffled, `playnext:<query>`
/// as Play Next, and a bare `play:` is "play music". The intent's own
/// `perform()` runs, `ready()` included, since the point is the path an
/// intent takes with nothing on screen yet.
enum SiriDevHook {
    static func run() {
        guard let spec = ProcessInfo.processInfo.environment["CTUNES_DEV_INTENT"], !spec.isEmpty else { return }
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Siri")
        Task { @MainActor in
            do {
                let said = try await perform(spec, log: log)
                let player = AppRuntime.shared.player
                let playing = player.currentTrack.map { "\($0.title) — \($0.grandparentTitle ?? "")" } ?? "nothing"
                log.info("intent \(spec, privacy: .public) ok: \(playing, privacy: .public), \(player.upcoming.count) up next, shuffle \(player.queue.isShuffled), repeat \(player.repeatMode.rawValue, privacy: .public); \(said, privacy: .public)")
            } catch {
                log.error("intent \(spec, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @MainActor
    private static func perform(_ spec: String, log: Logger) async throws -> String {
        switch spec {
        case "favorites":
            return try await ShuffleFavoritesIntent().perform().spokenLine
        case "rotation":
            return try await PlayOnRotationIntent().perform().spokenLine
        case "resume":
            return try await ResumeIntent().perform().spokenLine
        default:
            break
        }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let command = parts.first ?? spec
        let argument = parts.count == 2 ? parts[1] : ""
        switch command {
        case "playlist", "shuffle":
            guard let entity = try await PlaylistQuery().entities(matching: argument).first else {
                throw IntentFailure.noSuchPlaylist
            }
            if command == "shuffle" {
                let intent = ShufflePlaylistIntent()
                intent.playlist = entity
                return try await intent.perform().spokenLine
            }
            let intent = PlayPlaylistIntent()
            intent.playlist = entity
            return try await intent.perform().spokenLine
        case "search":
            let hits = try await search(argument)
            for hit in hits { log.info("hit \(describe(hit), privacy: .public)") }
            return "\(hits.count) hits"
        case "play", "playshuffle", "playnext":
            guard let hit = try await search(argument).first else { throw IntentFailure.noSuchItem }
            log.info("picked \(describe(hit), privacy: .public)")
            let intent = PlayAudioIntent(
                audioEntity: hit,
                playbackAttributes: command == "playshuffle" ? [.shuffle] : [],
                queueLocation: command == "playnext" ? .next : nil
            )
            return try await intent.perform().spokenLine
        default:
            throw IntentFailure.nothingToPlay
        }
    }

    @MainActor
    private static func search(_ query: String) async throws -> [AudioEntity] {
        let criteria: AudioSearch.Criteria = query.isEmpty ? .unspecified : .searchQuery(query)
        return try await AudioSearchQuery().values(for: AudioSearch(criteria: criteria))
    }

    private static func describe(_ entity: AudioEntity) -> String {
        switch entity {
        case .artist(let artist): "artist \(artist.name) [\(artist.id)]"
        case .album(let album): "album \(album.title) by \(album.artistName) [\(album.id)]"
        case .song(let song): "song \(song.title) by \(song.artistName) on \(song.albumTitle ?? "?") [\(song.id)]"
        case .playlist(let playlist): "playlist \(playlist.title) [\(playlist.id)]"
        }
    }
}

private extension IntentResult {
    /// `IntentDialog` keeps its text to itself, so the log reads the
    /// player instead; this is a placeholder for the intents.
    var spokenLine: String { "" }
}
#endif
