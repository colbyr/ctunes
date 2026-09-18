import AppIntents
import PlexKit

// The App Shortcuts: the phrases Siri answers on any phone, with no
// Apple Intelligence and no schema, and the actions Shortcuts lists.
// Each is `AudioPlaybackIntent`, so it runs in the app process in the
// background and the phone stays where it is. The paths are
// `IntentPlayback`'s; the plan is `notes/siri.md`.

struct ShuffleFavoritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Favorites"
    static let description = IntentDescription("Plays every favorited track, shuffled.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = try await IntentPlayback.ready()
        let count = try await playback.shuffleFavorites()
        return .result(dialog: "Shuffling \(count) favorites.")
    }
}

struct PlayOnRotationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play On Rotation"
    static let description = IntentDescription("Plays the albums you've had on lately, front to back.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = try await IntentPlayback.ready()
        let albums = try await playback.playOnRotation()
        guard let first = albums.first else { return .result(dialog: "Playing On Rotation.") }
        return .result(dialog: "Playing On Rotation, starting with \(first.title) by \(first.parentTitle ?? "").")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist front to back.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") }

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = try await IntentPlayback.ready()
        let found = try await playback.playlist(ratingKey: playlist.ratingKey)
        _ = try await playback.play(playlist: found, shuffled: false)
        return .result(dialog: "Playing \(found.title).")
    }
}

struct ShufflePlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist"
    static let description = IntentDescription("Plays a playlist shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Shuffle \(\.$playlist)") }

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = try await IntentPlayback.ready()
        let found = try await playback.playlist(ratingKey: playlist.ratingKey)
        _ = try await playback.play(playlist: found, shuffled: true)
        return .result(dialog: "Shuffling \(found.title).")
    }
}

struct ResumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Picks up where the queue left off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = try await IntentPlayback.ready()
        let track = try playback.resume()
        return .result(dialog: "Resuming \(track.title).")
    }
}

/// Registered at install and refreshed by `updateAppShortcutParameters()`
/// when the playlists change. Every phrase has to carry the app's name;
/// "Tunes" alone works through `INAlternativeAppNames` in `Info.plist`.
struct CtunesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShuffleFavoritesIntent(),
            phrases: [
                "Shuffle my favorites in \(.applicationName)",
                "Shuffle favorites in \(.applicationName)",
                "Play my favorites in \(.applicationName)",
                "Shuffle my favorite songs in \(.applicationName)",
            ],
            shortTitle: "Shuffle Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayOnRotationIntent(),
            phrases: [
                "Play On Rotation in \(.applicationName)",
                "Play what's on rotation in \(.applicationName)",
                "Play something in \(.applicationName)",
                "Play music in \(.applicationName)",
            ],
            shortTitle: "Play On Rotation",
            systemImageName: "arrow.trianglehead.2.clockwise.rotate.90"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play the \(\.$playlist) playlist in \(.applicationName)",
                "Play my \(\.$playlist) playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: ShufflePlaylistIntent(),
            phrases: [
                "Shuffle \(\.$playlist) in \(.applicationName)",
                "Shuffle the \(\.$playlist) playlist in \(.applicationName)",
                "Shuffle my \(\.$playlist) playlist in \(.applicationName)",
            ],
            shortTitle: "Shuffle Playlist",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume in \(.applicationName)",
                "Keep playing \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
