import AppIntents
import PlexKit

/// "Play Loveless", "Shuffle the Velvet Underground", "Play Sunday
/// Morning next": the `.audio.playAudio` schema intent, whose entity Siri
/// resolved through `AudioSearchQuery`. The queue is what the item's own
/// page would play (`IntentPlayback.play(_:attributes:location:)`), the
/// vetoes from `notes/listeners.md` included.
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays an artist, album, song or playlist from your Plex library.")

    var audioEntity: AudioEntity
    var playbackAttributes: Set<PlaybackAttribute>
    var queueLocation: QueueInsertionLocation?
    /// The schema asks for it; nothing warms a queue yet (S5), so it is
    /// never set and never read.
    var warmupAudioQueueResult: WarmupAudioQueueResult?

    init() {
        audioEntity = .artist(ArtistEntity(ratingKey: "", name: "", server: ""))
        playbackAttributes = []
    }

    init(audioEntity: AudioEntity, playbackAttributes: Set<PlaybackAttribute> = [], queueLocation: QueueInsertionLocation? = nil) {
        self.audioEntity = audioEntity
        self.playbackAttributes = playbackAttributes
        self.queueLocation = queueLocation
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        siriLog.info("play asked: \(audioEntity.logName, privacy: .public), \(playbackAttributes.map(\.rawValue).joined(separator: ","), privacy: .public), \(queueLocation?.rawValue ?? "replace", privacy: .public)")
        let playback = try await IntentPlayback.ready()
        do {
            let dialog = try await playback.play(audioEntity, attributes: playbackAttributes, location: queueLocation)
            siriLog.info("play done: \(dialog, privacy: .public)")
            return .result(dialog: "\(dialog)")
        } catch {
            siriLog.error("play failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

/// The schema's handle on a queue prepared ahead of the answer. There is
/// no warmup intent yet, so none is ever made or looked up.
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Queue")
    }
}
