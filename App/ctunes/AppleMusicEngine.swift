import AVFoundation
import Combine
import Foundation
import MediaPlayer
@preconcurrency import MusicKit
import PlexKit
import os

/// SPIKE (COL-117): plays an Apple Music song inside `AudioPlayer`'s own
/// queue. Apple Music audio is DRM'd and never reaches `AVPlayer`, so an
/// Apple Music entry is handed to `ApplicationMusicPlayer` as a queue of
/// one, watched until it ends, and the queue advances by hand as it does
/// for Plex.
///
/// An entry is a `PlexTrack` whose `ratingKey` is `am:<catalog id>`, decoded
/// from a hand-built payload, so the queue, Up Next and shuffle need no
/// changes. The `Song` itself is kept here by that key.
///
/// Everything it learns is logged under category `AppleMusic`:
/// `log show --info --predicate 'category == "AppleMusic" || category == "AudioPlayer"'`.
@MainActor
final class AppleMusicEngine {
    enum Event {
        /// The clock started for the entry loaded.
        case running(Bool)
        case ended
        /// MusicKit moved to the padding after the song before it was
        /// over: a "next" from the lock screen or the car, which goes to
        /// MusicKit and never to our command handlers.
        case skippedNext
        /// MusicKit moved to the padding before the song: a "previous"
        /// pressed early in it. Later in the song MusicKit restarts it
        /// itself and no event is needed.
        case skippedPrevious
        /// Shuffle or repeat pressed where the press goes to MusicKit (the
        /// car's Now Playing): one press each.
        case shuffleToggled
        case repeatCycled
        /// MusicKit paused or played with nobody here asking: the lock
        /// screen talking to MusicKit directly, or an interruption.
        case pausedExternally
        case resumedExternally
        case failed(Error)
    }

    var onEvent: (@MainActor (Event) -> Void)?
    var onTime: (@MainActor (Double) -> Void)?
    /// Whether the current queue entry is MusicKit's.
    private(set) var isActive = false
    private(set) var isRunning = false
    private(set) var currentTime: Double = 0

    private let player = ApplicationMusicPlayer.shared
    private var songs: [String: Song] = [:]
    private var activeKey: String?
    private var activeDuration: Double = 0
    /// Whether playback is wanted here, to tell our pauses from MusicKit's.
    private var wantsPlaying = false
    private var loadedAt: ContinuousClock.Instant?
    private var poll: Task<Void, Never>?
    private var lastStatus: MusicKit.MusicPlayer.PlaybackStatus?
    private var lastEntryID: String?
    private var endHandled = false
    /// The furthest the clock got while running: MusicKit reads 0 again
    /// once a queue of one plays out, sometimes before it reports paused.
    private var furthest: Double = 0
    /// Set on the first `.playing` after a load. Before it, MusicKit walks
    /// stopped → paused → playing while it prepares, which read as someone
    /// else pausing and resuming: the play button flickered at the switch.
    private var hasStarted = false
    /// Whether to give up our audio session before MusicKit starts. Ours is
    /// non-mixable, and MusicKit plays from RemotePlayerService under a
    /// session of its own.
    static var releasesSession: Bool {
        get { UserDefaults.standard.object(forKey: "amSpike.releaseSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amSpike.releaseSession") }
    }
    /// Whether the song is loaded between two paddings (the same song
    /// again), so a remote "next" or "previous", which MusicKit handles
    /// itself, shows up as the current entry moving. With a queue of one
    /// a "next" only reset the clock and paused.
    static var padsQueue: Bool {
        get { UserDefaults.standard.object(forKey: "amSpike.padQueue") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amSpike.padQueue") }
    }
    /// Where the song sits in MusicKit's queue: 1 when padded.
    private var songPosition = 0
    /// Whether the load has put MusicKit on the song, so an entry change
    /// from here on is someone else's.
    private var settled = false
    /// MusicKit's queue and state announcing a change, so a remote next
    /// is acted on as it lands rather than up to a poll (250ms) later,
    /// which let that much of the padding be heard.
    private var endTimer: Task<Void, Never>?
    private var queueWatch: AnyCancellable?
    private var stateWatch: AnyCancellable?
    /// Bumped on every load and stop, so a slow `prepareToPlay` for an
    /// entry already left doesn't start it.
    private var generation = 0
    let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "AppleMusic")

    static func isAppleMusic(_ track: PlexTrack) -> Bool {
        track.ratingKey.hasPrefix("am:")
    }

    // MARK: - Entries

    /// The queue entry for `song`, remembered so it can load later.
    func entry(for song: Song) -> PlexTrack? {
        let key = "am:\(song.id.rawValue)"
        songs[key] = song
        var payload: [String: Any] = [
            "ratingKey": key,
            "title": song.title,
            "grandparentTitle": song.artistName,
            "grandparentRatingKey": "am-artist:\(song.artistName)",
            "parentTitle": song.albumTitle ?? "",
            "parentRatingKey": "am-album:\(song.albumTitle ?? song.id.rawValue)",
        ]
        if let duration = song.duration { payload["duration"] = Int(duration * 1000) }
        if let thumb = song.artwork?.url(width: 900, height: 900)?.absoluteString {
            payload["thumb"] = thumb
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(PlexTrack.self, from: data)
    }

    func artworkURL(for track: PlexTrack) -> URL? {
        track.thumb.flatMap(URL.init(string:))
    }

    // MARK: - Transport

    func load(_ track: PlexTrack, autoPlay: Bool, startAt: Double) {
        guard let song = songs[track.ratingKey] else {
            log.error("no song for \(track.ratingKey, privacy: .public)")
            onEvent?(.failed(CancellationError()))
            return
        }
        generation += 1
        let generation = generation
        isActive = true
        activeKey = track.ratingKey
        activeDuration = song.duration ?? 0
        wantsPlaying = autoPlay
        endHandled = false
        currentTime = startAt
        furthest = startAt
        hasStarted = false
        settled = false
        isRunning = false
        endTimer?.cancel()
        endTimer = nil
        loadedAt = .now
        logNowPlaying("before load")
        log.notice("load \(song.title, privacy: .public) autoPlay=\(autoPlay) startAt=\(startAt, format: .fixed(precision: 1))")
        startPolling()
        Task {
            do {
                if Self.holdsMixableSession {
                    Self.holdMixableSession(log: log)
                } else if Self.releasesSession {
                    Self.releaseOurSession(log: log)
                }
                // Coming straight from another Apple Music entry MusicKit is
                // still winding the old queue down; let it, before the swap.
                if player.state.playbackStatus == .playing { player.pause() }
                let swapping = ContinuousClock.now
                while player.state.playbackStatus == .playing, ContinuousClock.now - swapping < .milliseconds(400) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard generation == self.generation else { return }
                // MusicKit's own shuffle would reorder the padding and its
                // repeat would loop it; ours are the queue's. Both stay
                // off there and a change is read as a press (`mirrorModes`).
                player.state.shuffleMode = .off
                player.state.repeatMode = MusicKit.MusicPlayer.RepeatMode.none
                if Self.padsQueue {
                    let entries = [song, song, song].map { ApplicationMusicPlayer.Queue.Entry($0) }
                    player.queue = ApplicationMusicPlayer.Queue(entries, startingAt: entries[1])
                } else {
                    player.queue = [song]
                    songPosition = 0
                }
                watchChanges()
                try await player.prepareToPlay()
                guard generation == self.generation else { return }
                // `startingAt` is not honoured for three entries of one
                // song (measured: the first was current), so step onto the
                // middle one by hand and trust only where it really is.
                // The new queue's current entry can still be unset when
                // `prepareToPlay` returns. Read then, the step below was
                // skipped and the song sat first with nothing before it,
                // so a remote "previous" could only restart it.
                let prepared = ContinuousClock.now
                while currentPosition() == nil, ContinuousClock.now - prepared < .seconds(1) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard generation == self.generation else { return }
                log.notice("current entry known \(ContinuousClock.now - prepared, privacy: .public) after prepare, position \(self.currentPosition() ?? -1)")
                if Self.padsQueue, currentPosition() == 0 {
                    // The queue's current entry lags the call returning:
                    // read at once it still said the first, and the tick
                    // then took the step for a remote "next". And a step
                    // asked right after the queue replaced one that was
                    // still playing (Apple Music straight after Apple
                    // Music) returned without moving at all, so it is
                    // checked and asked again.
                    let asked = ContinuousClock.now
                    var attempts = 0
                    while currentPosition() == 0, attempts < 5 {
                        attempts += 1
                        try await player.skipToNextEntry()
                        let tried = ContinuousClock.now
                        while currentPosition() == 0, ContinuousClock.now - tried < .milliseconds(400) {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        guard generation == self.generation else { return }
                    }
                    log.notice("stepped onto the middle entry after \(ContinuousClock.now - asked, privacy: .public) and \(attempts) ask(s), position \(self.currentPosition() ?? -1)")
                    if !autoPlay { player.pause() }
                }
                songPosition = currentPosition() ?? 0
                lastEntryID = player.queue.currentEntry?.id
                settled = true
                let ids = player.queue.entries.map(\.id).joined(separator: ", ")
                log.notice("queue padded=\(Self.padsQueue) entries=[\(ids, privacy: .public)] current=\(self.player.queue.currentEntry?.id ?? "nil", privacy: .public) songPosition=\(self.songPosition)")
                if startAt > 0 { player.playbackTime = startAt }
                if autoPlay { try await player.play() }
                let elapsed = loadedAt.map { ContinuousClock.now - $0 } ?? .zero
                log.notice("prepared+play returned after \(elapsed, privacy: .public)")
                // What the lock screen holds once MusicKit has started: did
                // it overwrite ours?
                try? await Task.sleep(for: .seconds(1))
                logNowPlaying("1s after start")
                try? await Task.sleep(for: .seconds(3))
                logNowPlaying("4s after start")
            } catch {
                guard generation == self.generation else { return }
                log.error("load failed: \(error, privacy: .public)")
                onEvent?(.failed(error))
            }
        }
    }

    func play() {
        wantsPlaying = true
        Task {
            do { try await player.play() } catch {
                log.error("play failed: \(error, privacy: .public)")
            }
        }
    }

    func pause() {
        wantsPlaying = false
        player.pause()
    }

    func seek(to seconds: Double) {
        endHandled = false
        endTimer?.cancel()
        endTimer = nil
        furthest = seconds
        player.playbackTime = seconds
        currentTime = seconds
    }

    /// Hands the audio back: the next entry is Plex's, or the queue is gone.
    func stop() {
        guard isActive else { return }
        generation += 1
        log.notice("stop (handing back to AVPlayer)")
        wantsPlaying = false
        isActive = false
        isRunning = false
        activeKey = nil
        poll?.cancel()
        poll = nil
        queueWatch = nil
        stateWatch = nil
        endTimer?.cancel()
        endTimer = nil
        player.stop()
        player.queue = []
    }

    private func currentPosition() -> Int? {
        guard let id = player.queue.currentEntry?.id else { return nil }
        return player.queue.entries.map(\.id).firstIndex(of: id)
    }

    /// Waits for MusicKit to stop after `stop()`. In the background iOS
    /// refuses our session while RemotePlayerService still plays ("can't
    /// stop others because it is in the background and not the NowPlaying
    /// app"), so the handoff back to AVPlayer has to follow it, not race it.
    func quiesce() async {
        let start = ContinuousClock.now
        while player.state.playbackStatus == .playing, ContinuousClock.now - start < .seconds(1) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let stopped = ContinuousClock.now - start
        try? await Task.sleep(for: .milliseconds(200))
        log.notice("quiesced: MusicKit status \(String(describing: self.player.state.playbackStatus), privacy: .public) after \(stopped, privacy: .public), +200ms")
    }

    // MARK: - Watching

    /// MusicKit's state is an `ObservableObject`; a poll is simpler to
    /// reason about for a spike and logs every transition it sees.
    private func startPolling() {
        poll?.cancel()
        lastStatus = nil
        lastEntryID = nil
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// `objectWillChange` fires before the value lands, so the look is
    /// taken a hop later and once more after 40ms. `tick` only acts on
    /// differences, so the extra looks are free.
    private func watchChanges() {
        let look: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.tick()
                try? await Task.sleep(for: .milliseconds(40))
                self?.tick()
            }
        }
        queueWatch = player.queue.objectWillChange.sink { _ in look() }
        stateWatch = player.state.objectWillChange.sink { _ in look() }
    }

    private func tick() {
        guard isActive else { return }
        let status = player.state.playbackStatus
        let time = player.playbackTime
        let entryID = player.queue.currentEntry?.id
        if status != lastStatus {
            let since = loadedAt.map { ContinuousClock.now - $0 } ?? .zero
            log.notice("status \(String(describing: self.lastStatus), privacy: .public) → \(String(describing: status), privacy: .public) at \(time, format: .fixed(precision: 2))s / \(self.activeDuration, format: .fixed(precision: 1))s, \(since, privacy: .public) since load, entry=\(entryID ?? "nil", privacy: .public)")
            handle(status: status, previous: lastStatus, time: time)
            lastStatus = status
        }
        if entryID != lastEntryID {
            log.notice("currentEntry \(self.lastEntryID ?? "nil", privacy: .public) → \(entryID ?? "nil", privacy: .public) at \(time, format: .fixed(precision: 2))s")
            // Not before the load settles: the entry is briefly nil while
            // the queue is swapped, and the change watchers look right then.
            if lastEntryID != nil, entryID == nil, !endHandled, settled {
                log.notice("end: current entry went away")
                ended()
                return
            }
            if lastEntryID != nil, let entryID, !endHandled, hasStarted, moved(to: entryID, at: time) {
                lastEntryID = entryID
                return
            }
            lastEntryID = entryID
        }
        mirrorModes()
        // The clock can read 0 again once the queue has played out, so the
        // end is judged on the last time seen while it was running.
        // Not before the load settles: the clock is still the last song's
        // (148s shown for a tick on a song just started).
        if status == .playing, settled {
            // At the end the clock reads 0 for a tick before the status
            // says paused; passing it on sent the scrubber back to the start.
            let resetAtEnd = activeDuration > 0 && furthest >= activeDuration - 3 && time < 1
            guard !resetAtEnd else { return }
            // MusicKit restarting the song for a "previous" pressed later
            // in it, or a scrub from the lock screen: the end is judged
            // from here again.
            if time < furthest - 2 {
                log.notice("clock went back \(self.furthest, format: .fixed(precision: 2))s → \(time, format: .fixed(precision: 2))s with the entry unchanged (restart or seek inside MusicKit)")
                furthest = time
            }
            currentTime = time
            furthest = max(furthest, time)
            onTime?(time)
            preemptEnd(from: time)
        }
    }

    private func handle(status: MusicKit.MusicPlayer.PlaybackStatus, previous: MusicKit.MusicPlayer.PlaybackStatus?, time: Double) {
        // Until the load settles the status is the last queue's winding
        // down: passed on, it flipped the transport's running state and
        // the lock screen's rate at every Apple Music to Apple Music move.
        guard settled else { return }
        let running = status == .playing
        if running != isRunning {
            isRunning = running
            onEvent?(.running(running))
        }
        if running { hasStarted = true }
        guard previous != nil, hasStarted else { return }
        switch status {
        case .paused, .stopped:
            let nearEnd = activeDuration > 0 && furthest >= activeDuration - 3
            if wantsPlaying, nearEnd || status == .stopped, !endHandled {
                log.notice("end: \(String(describing: status), privacy: .public) with furthest \(self.furthest, format: .fixed(precision: 2))s, clock \(time, format: .fixed(precision: 2))s")
                ended()
            } else if wantsPlaying {
                log.notice("paused by someone else (interruption or a remote command routed to MusicKit)")
                wantsPlaying = false
                onEvent?(.pausedExternally)
            }
        case .playing:
            if !wantsPlaying, previous == .paused {
                log.notice("resumed by someone else")
                wantsPlaying = true
                onEvent?(.resumedExternally)
            }
        case .interrupted:
            log.notice("interrupted")
        default:
            break
        }
    }

    /// Left to itself MusicKit rolls into the padding after the song and
    /// its opening is heard before the pause lands. So the end is taken
    /// here, 0.15s early, and MusicKit paused while still on the song.
    /// A song that runs longer than its catalog duration loses the
    /// difference; a shorter one still ends through `moved`.
    private func preemptEnd(from time: Double) {
        guard Self.padsQueue, settled, wantsPlaying, !endHandled, endTimer == nil, activeDuration > 0 else { return }
        let remaining = activeDuration - time
        guard remaining <= 1.5 else { return }
        let generation = generation
        endTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(remaining - 0.15, 0)))
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.endTimer = nil
            let now = self.player.playbackTime
            // A seek back, a pause or a move in the meantime: not the end.
            guard self.wantsPlaying, !self.endHandled,
                  self.player.state.playbackStatus == .playing,
                  self.currentPosition() == self.songPosition,
                  self.activeDuration - now <= 0.6 else {
                self.log.notice("end timer stood down at \(now, format: .fixed(precision: 2))s")
                return
            }
            self.log.notice("end: taken at \(now, format: .fixed(precision: 2))s / \(self.activeDuration, format: .fixed(precision: 2))s, before MusicKit rolls into the padding")
            self.wantsPlaying = false
            self.endHandled = true
            self.player.pause()
            self.onEvent?(.ended)
        }
    }

    /// The current entry changed under us. With the queue padded that is
    /// the song ending into the padding after it, or a remote next or
    /// previous. MusicKit is paused at once so the padding isn't heard.
    private func moved(to entryID: String, at time: Double) -> Bool {
        guard Self.padsQueue, settled else { return false }
        let ids = player.queue.entries.map(\.id)
        guard let position = ids.firstIndex(of: entryID) else {
            log.notice("entry \(entryID, privacy: .public) isn't in the queue [\(ids.joined(separator: ", "), privacy: .public)]")
            return false
        }
        guard position != songPosition else { return false }
        let nearEnd = activeDuration > 0 && furthest >= activeDuration - 3
        let wanted = wantsPlaying
        wantsPlaying = false
        endHandled = true
        player.pause()
        if position > songPosition {
            if nearEnd {
                log.notice("end: moved into the padding after the song, furthest \(self.furthest, format: .fixed(precision: 2))s")
                onEvent?(.ended)
            } else {
                log.notice("remote next inferred: moved into the padding after the song at furthest \(self.furthest, format: .fixed(precision: 2))s / \(self.activeDuration, format: .fixed(precision: 1))s (wantsPlaying=\(wanted))")
                onEvent?(.skippedNext)
            }
        } else {
            log.notice("remote previous inferred: moved into the padding before the song at furthest \(self.furthest, format: .fixed(precision: 2))s (wantsPlaying=\(wanted))")
            onEvent?(.skippedPrevious)
        }
        return true
    }

    /// Shuffle and repeat pressed in the car go to MusicKit too. Its modes
    /// are held off (see `load`), so one leaving off is one press: passed
    /// on as an event and put back.
    private func mirrorModes() {
        guard settled else { return }
        if let shuffle = player.state.shuffleMode, shuffle != .off {
            log.notice("MusicKit shuffleMode → \(String(describing: shuffle), privacy: .public): a shuffle press, mirrored")
            player.state.shuffleMode = .off
            onEvent?(.shuffleToggled)
        }
        if let repeatMode = player.state.repeatMode, repeatMode != MusicKit.MusicPlayer.RepeatMode.none {
            log.notice("MusicKit repeatMode → \(String(describing: repeatMode), privacy: .public): a repeat press, mirrored")
            player.state.repeatMode = MusicKit.MusicPlayer.RepeatMode.none
            onEvent?(.repeatCycled)
        }
    }

    private func ended() {
        endHandled = true
        onEvent?(.ended)
    }

    /// Whether our session stays active, but mixable, while MusicKit
    /// plays, instead of being released. Released, it has to interrupt
    /// MusicKit's to come back, and in the background iOS refuses that
    /// ("can't stop others because it is in the background and not the
    /// NowPlaying app"), even with MusicKit stopped. A mixable session
    /// interrupts nobody, so AVPlayer can start under it at the handoff.
    static var holdsMixableSession: Bool {
        get { UserDefaults.standard.object(forKey: "amSpike.mixableSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amSpike.mixableSession") }
    }

    static func holdMixableSession(log: Logger) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            log.notice("holding our audio session active and mixable")
        } catch {
            log.error("holding a mixable session failed: \(error, privacy: .public)")
        }
    }

    /// Deactivates our session, telling others they may resume, so
    /// MusicKit's starts with nothing non-mixable in its way.
    static func releaseOurSession(log: Logger) {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            log.notice("released our audio session")
        } catch {
            log.error("releasing our audio session failed: \(error, privacy: .public)")
        }
    }

    /// The control: MusicKit alone, no queue, no `AudioPlayer`.
    func rawPlay(_ song: Song) {
        log.notice("raw play \(song.title, privacy: .public), releasesSession=\(Self.releasesSession)")
        if Self.releasesSession { Self.releaseOurSession(log: log) }
        Task {
            do {
                player.queue = [song]
                try await player.play()
                log.notice("raw play returned, status \(String(describing: self.player.state.playbackStatus), privacy: .public)")
            } catch {
                log.error("raw play failed: \(error, privacy: .public)")
            }
        }
    }

    /// Spawns MusicKit's player with nothing of ours playing: prepares
    /// `song` and stops there. Tests whether a player created before Plex
    /// audio stays unmuted through later handoffs.
    func prewarm(_ song: Song) {
        log.notice("prewarm with \(song.title, privacy: .public)")
        Task {
            do {
                player.queue = [song]
                try await player.prepareToPlay()
                log.notice("prewarm prepared, status \(String(describing: self.player.state.playbackStatus), privacy: .public)")
            } catch {
                log.error("prewarm failed: \(error, privacy: .public)")
            }
        }
    }

    func logNowPlaying(_ moment: String) {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = info?[MPMediaItemPropertyTitle] as? String ?? "nil"
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate].map { "\($0)" } ?? "nil"
        let state = MPNowPlayingInfoCenter.default().playbackState.rawValue
        log.notice("nowPlaying[\(moment, privacy: .public)] title=\(title, privacy: .public) rate=\(rate, privacy: .public) playbackState=\(state) keys=\(info?.count ?? 0)")
    }
}
