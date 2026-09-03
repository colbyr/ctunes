import AVFoundation
import MediaPlayer
import Observation
import PlexKit
import SwiftUI

/// Plays a queue of Plex tracks and keeps the lock screen in sync.
///
/// The queue is managed here rather than with AVQueuePlayer: advancing by hand
/// on end-of-item keeps the current index, the now-playing metadata and the UI
/// in agreement, which AVQueuePlayer's implicit item advancement makes fiddly.
/// Gapless playback is explicitly out of scope and would need a different
/// design. The index bookkeeping itself lives in `PlayQueue` so it is tested
/// natively on macOS.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var queue = PlayQueue<PlexTrack>()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var repeatMode: RepeatMode = .off
    /// True once the last item has played out with nothing to follow it. The
    /// current track stays put so the header still has something to show;
    /// `resume` plays it again and `restart` goes back to the top.
    private(set) var hasEnded = false

    var isShuffled: Bool { queue.isShuffled }
    var currentTrack: PlexTrack? { queue.current }
    var upcoming: ArraySlice<PlayQueue<PlexTrack>.Entry> { queue.upcoming }

    private nonisolated let player = AVPlayer()
    private var library: PlexLibrary?
    @ObservationIgnored private nonisolated(unsafe) var timeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var endObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var itemStatusObserver: NSKeyValueObservation?
    /// How many times the current entry's item has been rebuilt after failing
    /// to load. Reset whenever the cursor moves.
    private var itemLoadRetries = 0
    private let maxItemLoadRetries = 2
    private var commandsConfigured = false

    /// One id per `play` call, so the server groups a listening session's
    /// timeline reports together.
    private var sessionIdentifier = UUID().uuidString
    private var lastReportedProgress: Double = 0
    /// Set once the current play-through has been handled as ended, so the
    /// notification and the clock fallback can't both advance the queue.
    private var itemEndHandled = false
    /// Plex counts a play from the periodic reports, so these have to keep
    /// flowing while a track plays; every 10s is what Plexamp does.
    private let reportInterval: Double = 10

    /// Restarting rather than stepping back is the platform convention once
    /// playback is a few seconds in.
    private let restartThreshold: Double = 3

    init() {
        player.actionAtItemEnd = .pause
        observeTime()
        observeItemEnd()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - Playback

    func play(_ tracks: [PlexTrack], startingAt index: Int, library: PlexLibrary) {
        reportTimeline(.stopped)
        self.library = library
        queue = PlayQueue(tracks, startingAt: index)
        sessionIdentifier = UUID().uuidString
        activateSession()
        configureRemoteCommands()
        loadCurrentItem(autoPlay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        // Nothing left to resume: a lock-screen play after the end starts over.
        if hasEnded {
            restart()
            return
        }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
        reportTimeline(.playing)
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
        reportTimeline(.paused)
    }

    /// A manual skip. Repeat-one is deliberately ignored here: skipping past
    /// a track you asked to hear again should still skip it.
    func next() {
        advance(wrapping: repeatMode == .all)
    }

    /// Plays the queue again from the top, whatever the repeat mode.
    func restart() {
        guard !queue.isEmpty else { return }
        reportTimeline(.stopped)
        queue.jump(to: 0)
        loadCurrentItem(autoPlay: true)
    }

    private func advance(wrapping: Bool) {
        // Report before the cursor moves so the stop lands on the right track.
        reportTimeline(.stopped)
        guard queue.advance(wrapping: wrapping) else {
            finish()
            return
        }
        loadCurrentItem(autoPlay: true)
    }

    /// The end of the line: stop where we are and flag it so the UI can say
    /// so. The head stays at the end rather than rewinding.
    private func finish() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
        hasEnded = true
        // Not `pause()`: the session is over, so the last report is a stop.
        reportTimeline(.stopped)
    }

    /// Reached from the end-of-item notification and from the clock fallback
    /// below, so it has to be safe to hit twice for one play-through.
    private func currentItemEnded() {
        guard !itemEndHandled else { return }
        itemEndHandled = true
        guard repeatMode != .one else {
            seek(to: 0)
            player.play()
            reportTimeline(.playing)
            return
        }
        advance(wrapping: repeatMode == .all)
    }

    // MARK: - Modes

    func toggleShuffle() {
        if queue.isShuffled { queue.unshuffle() } else { queue.shuffle() }
        updateNowPlayingModes()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        updateNowPlayingModes()
    }

    func previous() {
        // Check the threshold before retreating: retreat() moves the cursor.
        if currentTime > restartThreshold {
            seek(to: 0)
            return
        }
        guard queue.currentIndex > 0 else {
            seek(to: 0)
            return
        }
        reportTimeline(.stopped)
        _ = queue.retreat()
        loadCurrentItem(autoPlay: true)
    }

    func seek(to seconds: Double) {
        // Moving the head is a fresh run at the end of the item.
        itemEndHandled = false
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = seconds
                self?.updateNowPlayingPlaybackState()
            }
        }
    }

    // MARK: - Queue

    func playNext(_ tracks: [PlexTrack], library: PlexLibrary) {
        enqueue(tracks, library: library) { $0.playNext(tracks) }
    }

    func addToQueue(_ tracks: [PlexTrack], library: PlexLibrary) {
        enqueue(tracks, library: library) { $0.append(tracks) }
    }

    func jump(to entry: PlayQueue<PlexTrack>.Entry) {
        guard let index = queue.index(of: entry.id), index != queue.currentIndex else { return }
        reportTimeline(.stopped)
        queue.jump(to: index)
        loadCurrentItem(autoPlay: true)
    }

    func remove(_ entry: PlayQueue<PlexTrack>.Entry) {
        guard let index = queue.index(of: entry.id) else { return }
        if index == queue.currentIndex { reportTimeline(.stopped) }
        guard queue.remove(at: index) else { return }
        guard queue.current != nil else {
            player.replaceCurrentItem(with: nil)
            pause()
            hasEnded = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        loadCurrentItem(autoPlay: isPlaying)
    }

    /// With nothing queued, enqueueing is just starting playback; `library`
    /// is only needed on that path, since `play` is what stores it.
    private func enqueue(
        _ tracks: [PlexTrack],
        library: PlexLibrary,
        _ mutate: (inout PlayQueue<PlexTrack>) -> Void
    ) {
        guard !queue.isEmpty else {
            play(tracks, startingAt: 0, library: library)
            return
        }
        mutate(&queue)
    }

    // MARK: - Item loading

    private func loadCurrentItem(autoPlay: Bool) {
        guard let track = currentTrack,
              let library,
              let url = library.streamURL(for: track)
        else { return }

        itemLoadRetries = 0
        currentTime = 0
        duration = track.durationSeconds ?? 0
        hasEnded = false
        itemEndHandled = false
        loadItem(url: url, autoPlay: autoPlay)
        updateNowPlayingInfo(for: track)
        reportTimeline(isPlaying ? .playing : .paused)
    }

    /// Builds the player item for `url` and watches it fail. The first range
    /// request for a new track has been seen to die with `NSURLError -1005`
    /// when CFNetwork reuses a keep-alive connection the server has already
    /// dropped; AVPlayer then sits on the failed item forever, which looks
    /// like playback stopping after one track. A fresh item opens a fresh
    /// connection, so retry before giving up on the track.
    private func loadItem(url: URL, autoPlay: Bool) {
        let item = AVPlayerItem(url: url)
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.itemFailedToLoad(item, url: url) }
        }
        player.replaceCurrentItem(with: item)
        if autoPlay {
            player.play()
            isPlaying = true
        }
    }

    private func itemFailedToLoad(_ item: AVPlayerItem, url: URL) {
        // A stale observer from an item that was already replaced.
        guard player.currentItem === item else { return }
        if itemLoadRetries < maxItemLoadRetries {
            itemLoadRetries += 1
            loadItem(url: url, autoPlay: isPlaying)
            return
        }
        // The track is unplayable: move on rather than stall the queue. No
        // wrapping, so a server that is down doesn't cycle the queue forever.
        advance(wrapping: false)
    }

    // MARK: - Timeline

    /// Fire and forget: a slow server must never stall playback, and a lost
    /// report just means the next one carries the update.
    private func reportTimeline(_ state: PlaybackState) {
        guard let track = currentTrack, let library else { return }
        lastReportedProgress = currentTime
        let time = currentTime
        let session = sessionIdentifier
        Task {
            try? await library.reportTimeline(
                track, state: state, time: time, sessionIdentifier: session
            )
        }
    }

    private func reportProgressIfDue() {
        guard isPlaying else { return }
        // A seek can move the clock backwards, so compare on distance.
        guard abs(currentTime - lastReportedProgress) >= reportInterval else { return }
        reportTimeline(.playing)
    }

    /// Without an active `.playback` session, audio plays in the foreground and
    /// stops the moment the screen locks.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Hop to the main actor rather than asserting isolation: the observer
        // block isn't guaranteed to satisfy the main-thread dispatch assertion
        // even when the queue is .main, and assuming it crashes the process.
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateNowPlayingPlaybackState()
                self.reportProgressIfDue()
                self.finishIfRunPastEnd()
            }
        }
    }

    /// After a seek close to the end of a track, AVPlayer was observed to keep
    /// running the clock past the item's duration at rate 1 without ever
    /// posting `AVPlayerItemDidPlayToEndTime`. Treat the clock as the source
    /// of truth once it passes the end.
    private func finishIfRunPastEnd() {
        guard isPlaying, !itemEndHandled,
              let itemDuration = player.currentItem?.duration.seconds,
              itemDuration.isFinite, itemDuration > 0,
              currentTime >= itemDuration - 0.25
        else { return }
        currentItemEnded()
    }

    private func observeItemEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.currentItemEnded() }
        }
    }

    // MARK: - Lock screen

    private func configureRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self, self.isShuffled != (event.shuffleType != .off) else { return }
                self.toggleShuffle()
            }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                switch event.repeatType {
                case .off: self.repeatMode = .off
                case .one: self.repeatMode = .one
                case .all: self.repeatMode = .all
                @unknown default: break
                }
                self.updateNowPlayingModes()
            }
            return .success
        }
        updateNowPlayingModes()
    }

    /// Mirrors shuffle and repeat onto the lock-screen buttons.
    private func updateNowPlayingModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = switch repeatMode {
        case .off: .off
        case .one: .one
        case .all: .all
        }
    }

    private func updateNowPlayingInfo(for track: PlexTrack) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.grandparentTitle ?? "",
            MPMediaItemPropertyAlbumTitle: track.parentTitle ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = track.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        loadArtwork(for: track)
    }

    private func loadArtwork(for track: PlexTrack) {
        guard let library, let url = library.artworkURL(track.thumb, size: 600) else { return }
        let ratingKey = track.ratingKey

        Task {
            // Same URL the album and Now Playing views use, so this is
            // normally a cache hit.
            guard let image = await ImageLoader.shared.image(for: url) else { return }

            // Detached so the request handler below is built outside the main
            // actor. MediaPlayer invokes that handler on its own serial queue,
            // and a closure formed in a main-actor context traps the isolation
            // check when it does.
            Task.detached {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run { [weak self] in
                    // The queue may have moved on while this was in flight.
                    guard let self, self.currentTrack?.ratingKey == ratingKey else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
