import AVFoundation
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
    /// Whether to give up our audio session before MusicKit starts. Ours is
    /// non-mixable, and MusicKit plays from RemotePlayerService under a
    /// session of its own.
    static var releasesSession: Bool {
        get { UserDefaults.standard.object(forKey: "amSpike.releaseSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "amSpike.releaseSession") }
    }
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
        loadedAt = .now
        logNowPlaying("before load")
        log.notice("load \(song.title, privacy: .public) autoPlay=\(autoPlay) startAt=\(startAt, format: .fixed(precision: 1))")
        startPolling()
        Task {
            do {
                if Self.releasesSession { Self.releaseOurSession(log: log) }
                player.queue = [song]
                try await player.prepareToPlay()
                guard generation == self.generation else { return }
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
        player.stop()
        player.queue = []
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
            if lastEntryID != nil, entryID == nil, !endHandled {
                log.notice("end: current entry went away")
                ended()
                return
            }
            lastEntryID = entryID
        }
        // The clock can read 0 again once the queue has played out, so the
        // end is judged on the last time seen while it was running.
        if status == .playing {
            currentTime = time
            furthest = max(furthest, time)
            onTime?(time)
        }
    }

    private func handle(status: MusicKit.MusicPlayer.PlaybackStatus, previous: MusicKit.MusicPlayer.PlaybackStatus?, time: Double) {
        let running = status == .playing
        if running != isRunning {
            isRunning = running
            onEvent?(.running(running))
        }
        guard previous != nil else { return }
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

    private func ended() {
        endHandled = true
        onEvent?(.ended)
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

    func logNowPlaying(_ moment: String) {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = info?[MPMediaItemPropertyTitle] as? String ?? "nil"
        let rate = info?[MPNowPlayingInfoPropertyPlaybackRate].map { "\($0)" } ?? "nil"
        let state = MPNowPlayingInfoCenter.default().playbackState.rawValue
        log.notice("nowPlaying[\(moment, privacy: .public)] title=\(title, privacy: .public) rate=\(rate, privacy: .public) playbackState=\(state) keys=\(info?.count ?? 0)")
    }
}
