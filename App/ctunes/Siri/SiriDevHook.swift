#if DEBUG
import AppIntents
import Foundation
import os

/// `CTUNES_DEV_INTENT` runs one of the App Shortcuts a moment after
/// launch and logs the outcome under category `Siri`, so a simulator run
/// shows the whole path without Siri: `favorites`, `rotation`, `resume`,
/// `playlist:<name>` or `shuffle:<name>`, the name matched the way the
/// entity query matches what Siri heard. The intent's own `perform()`
/// runs, `ready()` included, since the point is the path an intent takes
/// with nothing on screen yet.
enum SiriDevHook {
    static func run() {
        guard let spec = ProcessInfo.processInfo.environment["CTUNES_DEV_INTENT"], !spec.isEmpty else { return }
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Siri")
        Task { @MainActor in
            do {
                try await perform(spec)
                let player = AppRuntime.shared.player
                let playing = player.currentTrack.map { "\($0.title) — \($0.grandparentTitle ?? "")" } ?? "nothing"
                log.info("intent \(spec, privacy: .public) ok: \(playing, privacy: .public), \(player.upcoming.count) up next")
            } catch {
                log.error("intent \(spec, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @MainActor
    private static func perform(_ spec: String) async throws {
        switch spec {
        case "favorites":
            _ = try await ShuffleFavoritesIntent().perform()
        case "rotation":
            _ = try await PlayOnRotationIntent().perform()
        case "resume":
            _ = try await ResumeIntent().perform()
        default:
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "playlist" || parts[0] == "shuffle" else {
                throw IntentFailure.nothingToPlay
            }
            guard let entity = try await PlaylistQuery().entities(matching: parts[1]).first else {
                throw IntentFailure.noSuchPlaylist
            }
            if parts[0] == "shuffle" {
                let intent = ShufflePlaylistIntent()
                intent.playlist = entity
                _ = try await intent.perform()
            } else {
                let intent = PlayPlaylistIntent()
                intent.playlist = entity
                _ = try await intent.perform()
            }
        }
    }
}
#endif
