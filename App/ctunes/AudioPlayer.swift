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

    var currentTrack: PlexTrack? { queue.current }
    var upcoming: ArraySlice<PlayQueue<PlexTrack>.Entry> { queue.upcoming }

    private nonisolated let player = AVPlayer()
    private var library: PlexLibrary?
    @ObservationIgnored private nonisolated(unsafe) var timeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var endObserver: NSObjectProtocol?
    private var commandsConfigured = false

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
        self.library = library
        queue = PlayQueue(tracks, startingAt: index)
        activateSession()
        configureRemoteCommands()
        loadCurrentItem(autoPlay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func next() {
        guard queue.advance() else {
            pause()
            seek(to: 0)
            return
        }
        loadCurrentItem(autoPlay: true)
    }

    func previous() {
        // Check the threshold before retreating: retreat() moves the cursor.
        if currentTime > restartThreshold {
            seek(to: 0)
            return
        }
        guard queue.retreat() else {
            seek(to: 0)
            return
        }
        loadCurrentItem(autoPlay: true)
    }

    func seek(to seconds: Double) {
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
        guard let index = queue.index(of: entry.id), queue.jump(to: index) else { return }
        loadCurrentItem(autoPlay: true)
    }

    func remove(_ entry: PlayQueue<PlexTrack>.Entry) {
        guard let index = queue.index(of: entry.id), queue.remove(at: index) else { return }
        guard queue.current != nil else {
            player.replaceCurrentItem(with: nil)
            pause()
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

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = 0
        duration = track.durationSeconds ?? 0

        if autoPlay {
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo(for: track)
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
            }
        }
    }

    private func observeItemEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next() }
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
