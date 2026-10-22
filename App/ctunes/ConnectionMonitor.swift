import Foundation
import Observation
import PlexKit
import os

/// Whether the server answers, and the work of finding it again: the
/// discovery that rides out a network handoff, the probe a failed fetch
/// or stream triggers (coalesced, and not repeated within seconds), the
/// foreground ping on a local address, and the retry timer while nothing
/// answers. The model opens the library and hands it here; the monitor
/// attaches and detaches the library's connection and publishes the
/// state the screens draw. Reachability is the server answering, never
/// a path monitor. Logs under category `Connection`.
@MainActor
@Observable
final class ConnectionMonitor {
    enum Connection: Equatable {
        /// The server answers at this address.
        case connected(PlexServer)
        /// Discovery is running: launch, a tap, the timer, or a probe
        /// after a failure.
        case searching
        /// Nothing answered. Saved copies and files on disk serve; the
        /// timer looks again.
        case unreachable
    }

    private(set) var connection: Connection = .searching
    /// Whether the search has run long enough to be worth a banner: a
    /// LAN answers within a second or two, and a banner would only flash.
    private(set) var searchingSlow = false
    /// The connection object the library holds while connected.
    private(set) var current: PlexLibrary?
    /// What the timer and "Try again" run: the model's connect, which
    /// finds the server and brings the library up. `force` skips the
    /// throttle and the offline debug hook.
    @ObservationIgnored var reconnect: (@MainActor (_ force: Bool) async -> Void)?

    private var client: PlexClient?
    private var token: String?
    private var library: CachedLibrary?
    /// The probe in flight when a fetch fails, so every screen that
    /// failed at once waits on the same one.
    private var rediscovery: Task<Bool, Never>?
    private var lastRediscovery: Date = .distantPast
    private static let rediscoverInterval: TimeInterval = 15
    private var lastReconnectAttempt: Date = .distantPast
    private static let reconnectInterval: TimeInterval = 30
    private var reconnecting = false
    /// The timer that looks for the server again while nothing answers,
    /// so a phone in a pocket comes back on its own. Backs off from 10s
    /// to a minute; a foreground or a tap resets nothing, they just try
    /// sooner.
    private var offlineRetry: Task<Void, Never>?
    private var offlineRetryDelay: TimeInterval = ConnectionMonitor.offlineRetryFloor
    private static let offlineRetryFloor: TimeInterval = 10
    private static let offlineRetryCeiling: TimeInterval = 60
    private var slowTimer: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Connection")

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func start(client: PlexClient, token: String) {
        self.client = client
        self.token = token
    }

    /// Signed out: nothing to look for.
    func stop() {
        cancelRetry()
        rediscovery?.cancel()
        rediscovery = nil
        current = nil
        library = nil
        client = nil
        token = nil
        setConnection(.searching)
    }

    /// The library whose connection this monitor keeps. A connection
    /// already up attaches to a new one at once.
    func watch(_ library: CachedLibrary?) async {
        guard library !== self.library else { return }
        self.library = library
        if let library, let current { await library.attach(current) }
    }

    // MARK: - Finding the server

    /// Discovery has started. The slow timer arms so a search that is
    /// still out after a few seconds earns a banner.
    func searching() {
        setConnection(.searching)
    }

    /// Discovery that rides out the handoff between networks. Wi-Fi drops
    /// a few seconds before cellular is up, and with `waitsForConnectivity`
    /// off every request in that gap fails at once, so one probe conceded
    /// to the saved library before the phone had a network to try. A
    /// transport failure is retried until `patience` runs out; plex.tv
    /// answering and no connection answering is the server itself away,
    /// and gets one more try in case the cellular path had just come up
    /// under it.
    func discover(patience: Duration) async throws -> PlexServer {
        guard let client, let token else { throw PlexError.notAuthenticated }
        let deadline = ContinuousClock.now + patience
        var unreachable = 0
        while true {
            do {
                return try await PlexServerDirectory(client: client).selectServer(token: token)
            } catch {
                if case PlexError.noServerReachable = error {
                    unreachable += 1
                    guard unreachable < 2 else { throw error }
                } else {
                    guard error is URLError else { throw error }
                }
                guard ContinuousClock.now + .seconds(2) < deadline else { throw error }
                log.notice("discovery failed, trying again: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
            }
        }
    }

    /// A connection on the server's address, for the model's own requests
    /// before it is declared connected: the section list has to land
    /// first, so a server that answered the probe and nothing else is a
    /// failed connect, not a connected one that then goes unreachable.
    func connection(for server: PlexServer) -> PlexLibrary? {
        guard let client, let token else { return nil }
        return PlexLibrary(client: client, server: server, token: token)
    }

    /// A server answered: its connection is the library's now. Attached
    /// to the library when one is watched.
    func connected(_ server: PlexServer, _ connection: PlexLibrary) async {
        current = connection
        cancelRetry()
        setConnection(.connected(server))
        log.notice("connected to \(server.baseURL.host() ?? "?", privacy: .public) local=\(server.isLocal)")
        if let library { await library.attach(connection) }
    }

    /// Nothing answered: the library's connection goes, the saved copies
    /// keep serving, and the timer looks again.
    func unreachable() async {
        current = nil
        await library?.detach()
        setConnection(.unreachable)
        scheduleRetry()
    }

    /// The banner's "Try again", the timer, and the scene coming back:
    /// throttled unless forced.
    func tryAgain(force: Bool) async {
        guard case .unreachable = connection, !reconnecting else { return }
        guard force || Date().timeIntervalSince(lastReconnectAttempt) > Self.reconnectInterval else { return }
        lastReconnectAttempt = Date()
        reconnecting = true
        defer { reconnecting = false }
        await reconnect?(force)
    }

    // MARK: - Failures

    /// Called by the library when a fetch fails on the transport, and by
    /// the player when a stream does. The address that failed is not
    /// necessarily the server: a phone that walked from Wi-Fi to cellular
    /// still holds the LAN address discovery picked, and the remote one
    /// answers fine. So the connections are probed again first and the
    /// library's connection swapped onto whichever answers, in place,
    /// under the same stack and queue. Only when nothing answers is the
    /// connection detached. Returns true when a server answered, so the
    /// caller can retry what failed.
    @discardableResult
    func failed(_ error: Error) async -> Bool {
        guard case .connected = connection, let current, Self.isConnectionError(error) else { return false }
        log.error("connection lost: \(String(describing: error), privacy: .public)")
        // A fetch that started before a swap fails on the old address
        // after it: the move already happened. Asking again inside the
        // probe's throttle read as nothing answering, and went offline
        // off a working address.
        if let failing = (error as? URLError)?.failingURL, failing.host() != current.baseURL.host() {
            log.notice("failure on an address already left, retrying on the current one")
            return true
        }
        if await rediscover() { return true }
        // Another caller may have detached while this one waited on the probe.
        guard case .connected = connection else { return false }
        log.error("nothing answered, browsing from disk")
        await unreachable()
        return false
    }

    /// The scene coming to the front. Unreachable, it is a reason to look
    /// again. Connected on a local address, the phone may have changed
    /// networks in the background and every screen's fetch would
    /// otherwise sit on the API timeout before rediscovery ran, so the
    /// address is pinged with a short timeout; a remote address works
    /// from anywhere and is left alone.
    func activated() async {
        switch connection {
        case .unreachable:
            await tryAgain(force: false)
        case .connected(let server) where server.isLocal:
            guard rediscovery == nil, Date().timeIntervalSince(lastRediscovery) > Self.rediscoverInterval,
                  let current else { return }
            guard await !current.ping() else { return }
            guard self.current === current else { return }
            log.notice("local address stopped answering while in the background")
            await failed(URLError(.cannotConnectToHost))
        case .connected, .searching:
            break
        }
    }

    /// Runs discovery again and, when the same server answers somewhere,
    /// attaches a fresh connection on that address. Coalesced: the
    /// screens that were mid-fetch all fail together and share one probe.
    /// Not repeated within a few seconds of the last one: a connection
    /// that keeps failing on an address that just answered is a server
    /// problem, not a route change, and the saved copies take over.
    private func rediscover() async -> Bool {
        if let rediscovery { return await rediscovery.value }
        guard Date().timeIntervalSince(lastRediscovery) > Self.rediscoverInterval, let current else { return false }
        let task = Task { () -> Bool in
            guard let server = try? await discover(patience: .seconds(25)),
                  self.current === current, server.machineIdentifier == current.serverIdentifier
            else { return false }
            // The same address answering means the failure was a moment,
            // not a move: the library asks again for what is on screen
            // either way.
            if server.baseURL != current.baseURL {
                log.notice("server moved to \(server.baseURL.host() ?? "?", privacy: .public) local=\(server.isLocal)")
            } else {
                log.notice("same address answered, asking again")
            }
            guard let connection = connection(for: server) else { return false }
            await connected(server, connection)
            return true
        }
        rediscovery = task
        let recovered = await task.value
        rediscovery = nil
        lastRediscovery = Date()
        return recovered
    }

    // MARK: - Timers

    private func scheduleRetry() {
        offlineRetry?.cancel()
        let delay = offlineRetryDelay
        offlineRetryDelay = min(delay * 2, Self.offlineRetryCeiling)
        offlineRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, case .unreachable = self.connection else { return }
            self.log.notice("offline retry after \(delay, format: .fixed(precision: 0))s")
            // Done as a timer before the attempt runs: a connect that
            // lands cancels the timer, and cancelling the task the attempt
            // itself runs in failed its next request with -999.
            self.offlineRetry = nil
            await self.tryAgain(force: true)
        }
    }

    private func cancelRetry() {
        offlineRetry?.cancel()
        offlineRetry = nil
        offlineRetryDelay = Self.offlineRetryFloor
    }

    private func setConnection(_ value: Connection) {
        guard value != connection else { return }
        connection = value
        slowTimer?.cancel()
        searchingSlow = false
        if case .searching = value {
            slowTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, case .searching = self.connection else { return }
                self.searchingSlow = true
            }
        }
    }

    /// A cancelled fetch is the screen going away, not the server.
    static func isConnectionError(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case PlexError.noServerReachable = error { return true }
        return false
    }

    /// Debug-only: skip discovery and open the saved library as if the
    /// server were unreachable, until "Try again" is tapped, which
    /// connects for real.
    static var forceOffline: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_OFFLINE"] == "1"
        #else
        false
        #endif
    }
}
