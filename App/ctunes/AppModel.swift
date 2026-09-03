import AuthenticationServices
import Observation
import PlexKit
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum State: Equatable {
        case loading
        case signedOut
        /// Waiting on the user to approve the device in a browser.
        case linking(code: String)
        /// Signed in, looking for a reachable server.
        case connecting
        case connectFailed
        case signedIn
        /// The server can't be reached but a snapshot can: browsing works
        /// from it and pinned albums play. A peer of `signedIn`, rendered
        /// by the same view so the stack and the queue survive the switch.
        case offline
    }

    private(set) var state: State = .loading
    var errorMessage: String?

    /// Set once a server has been reached, or a snapshot opened; the browse
    /// views read it.
    private(set) var library: (any LibrarySource)?
    /// Bumped whenever `library` is replaced, so screens re-run their `.task`.
    private(set) var libraryGeneration = 0
    /// True while an offline "Try again" is in flight.
    private(set) var reconnecting = false
    private(set) var serverName: String?

    /// Pinned albums and their download state, for the views.
    let downloads: Downloads
    private let offline: OfflineStore
    private var lastReconnectAttempt: Date = .distantPast
    private static let reconnectInterval: TimeInterval = 30

    /// Music libraries on the server, and the one being browsed. A server can
    /// expose several (audiobooks also report type "artist"), so the choice is
    /// remembered rather than asked for on every launch.
    private(set) var sections: [PlexSection] = []
    private(set) var selectedSection: PlexSection?

    /// Hearts toggled in this session, keyed by ratingKey. Tracks are
    /// immutable values fetched per screen and also held in the player's
    /// queue, so a toggle is layered over them here rather than pushed into
    /// every copy.
    private var favoriteOverrides: [String: Bool] = [:]

    /// People who share the phone and the artists they'd rather skip. Kept on
    /// the device, never in Plex, so it survives sign-out like any setting.
    private(set) var roster = ListenerRoster()

    private static let sectionDefaultsKey = "selected-section-key"
    private static let rosterDefaultsKey = "listeners"
    private static let serverDefaultsKey = "last-server-id"

    private var auth: PlexAuth?
    private var client: PlexClient?
    private var token: String?

    /// ASWebAuthenticationSession requires a callback scheme, but Plex never
    /// redirects to one: forwardUrl is ignored for a custom scheme and the
    /// browser lands on watch.plex.tv instead. The sheet is dismissed by
    /// cancelling its task once polling sees the token.
    private static let callbackScheme = "ctunes"

    init(offline: OfflineStore, cache: TrackCache) {
        self.offline = offline
        downloads = Downloads(store: offline, cache: cache)
        roster = Self.loadRoster()
        seedDevelopmentListeners()
    }

    func bootstrap() async {
        do {
            let identity = try PlexIdentity.persistent()
            let client = PlexClient(identity: identity)
            let auth = PlexAuth(client: client)
            self.client = client
            self.auth = auth

            let stored = try await auth.storedToken()
            if let existing = Self.developmentToken() ?? stored {
                token = existing
                await connect()
            } else {
                state = .signedOut
            }
        } catch {
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func signIn(using session: WebAuthenticationSession) async {
        guard let auth else { return }
        errorMessage = nil

        do {
            let pin = try await auth.requestPin()
            state = .linking(code: pin.code)

            let url = await auth.authURL(for: pin)

            // Poll while the sheet is open rather than after it closes.
            // Nothing redirects back to the app, so the token has to be
            // noticed here; seeing it cancels the sheet's task, which
            // dismisses it.
            let found = try await withThrowingTaskGroup(of: String?.self, returning: String?.self) { group in
                group.addTask {
                    // The sheet finishing tells us nothing on its own; the
                    // pin check below decides the outcome either way.
                    _ = try? await session.authenticate(
                        using: url,
                        callbackURLScheme: Self.callbackScheme
                    )
                    return nil
                }
                group.addTask {
                    try await auth.waitForAuthorization(pin: pin, timeout: .seconds(180))
                }

                while let result = try await group.next() {
                    if let token = result {
                        group.cancelAll()
                        return token
                    }
                    // Browser closed first. Approval may still have landed.
                    if let checked = try? await auth.checkPin(pin.id),
                       let token = checked.authToken, !token.isEmpty {
                        group.cancelAll()
                        return token
                    }
                    group.cancelAll()
                    return nil
                }
                return nil
            }

            guard let found else {
                state = .signedOut
                errorMessage = "Sign-in was cancelled before the device was linked."
                return
            }
            token = found
            await connect()
        } catch {
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    /// Lets a debug build skip the browser hand-off by taking a token from
    /// the environment, so the browse screens can be driven in a simulator.
    /// Compiled out of release builds entirely.
    private static func developmentToken() -> String? {
        #if DEBUG
        let token = ProcessInfo.processInfo.environment["CTUNES_DEV_TOKEN"]
        return (token?.isEmpty == false) ? token : nil
        #else
        return nil
        #endif
    }

    /// Finds a reachable server and opens the library on it. Falls back to
    /// the last snapshot when nothing answers, so the app is still usable
    /// with the server off.
    func connect() async {
        if state == .offline {
            await reconnect(force: true)
            return
        }
        state = .connecting
        await attemptConnect(tapped: false)
    }

    /// The offline banner's "Try again", and the scene coming back to the
    /// foreground: throttled unless tapped, and never passes through
    /// `.connecting`, so the stack stays put.
    func reconnect(force: Bool = false) async {
        guard state == .offline, !reconnecting else { return }
        guard force || Date().timeIntervalSince(lastReconnectAttempt) > Self.reconnectInterval else { return }
        lastReconnectAttempt = Date()
        reconnecting = true
        defer { reconnecting = false }
        await attemptConnect(tapped: force)
    }

    private func attemptConnect(tapped: Bool) async {
        guard let client, let token else { return }
        do {
            if Self.forceOffline, !tapped { throw PlexError.noServerReachable }
            let server = try await PlexServerDirectory(client: client).selectServer(token: token)
            let library = PlexLibrary(client: client, server: server, token: token)
            let sections = try await library.musicSections()

            self.library = library
            serverName = server.name
            self.sections = sections
            let saved = UserDefaults.standard.string(forKey: Self.sectionDefaultsKey)
            selectedSection = sections.first { $0.key == saved } ?? sections.first.flatMap {
                sections.count == 1 ? $0 : nil
            }
            UserDefaults.standard.set(server.machineIdentifier, forKey: Self.serverDefaultsKey)
            libraryGeneration += 1
            errorMessage = nil
            state = .signedIn
            downloads.attach(server: server.machineIdentifier)
            await resumeDownloads()
            await syncFavoritesPin()
        } catch {
            errorMessage = error.localizedDescription
            // Already offline: stay there; the banner shows the error.
            guard state != .offline else { return }
            if let snapshot = await lastSnapshot() {
                enterOffline(snapshot)
            } else {
                state = .connectFailed
            }
        }
    }

    private func lastSnapshot() async -> LibrarySnapshot? {
        guard let server = UserDefaults.standard.string(forKey: Self.serverDefaultsKey) else { return nil }
        let section = UserDefaults.standard.string(forKey: Self.sectionDefaultsKey)
        return await offline.snapshot(server: server, section: section)
    }

    private func enterOffline(_ snapshot: LibrarySnapshot) {
        library = OfflineLibrary(snapshot: snapshot, store: offline)
        serverName = snapshot.serverName
        sections = snapshot.sections
        selectedSection = snapshot.section
        libraryGeneration += 1
        state = .offline
        downloads.attach(server: snapshot.server)
    }

    /// Called by a browse screen when a fetch fails while signed in. A
    /// server that has gone away mid-session flips to the snapshot in
    /// place; with no snapshot nothing changes, as before.
    func connectionLost(_ error: Error) async {
        guard state == .signedIn, Self.isConnectionError(error) else { return }
        guard let snapshot = await lastSnapshot() else { return }
        errorMessage = error.localizedDescription
        enterOffline(snapshot)
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case PlexError.noServerReachable = error { return true }
        return false
    }

    /// Debug-only: skip discovery and open the last snapshot as if the
    /// server were unreachable, until "Try again" is tapped, which connects
    /// for real.
    private static var forceOffline: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CTUNES_DEV_OFFLINE"] == "1"
        #else
        false
        #endif
    }

    // MARK: - Snapshot

    /// Saves what the browse root just loaded, plus the artists, so the
    /// next launch can browse without the server. Keyed by section, so
    /// switching libraries snapshots each on first browse. Also brings the
    /// favorites pin up to date with the set as the server has it.
    func snapshot(albums: [PlexAlbum], favorites: [PlexTrack]) async {
        guard let library, !library.isOffline, let section = selectedSection else { return }
        guard let artists = try? await library.artists(inSection: section.key) else { return }
        let snapshot = LibrarySnapshot(
            server: library.serverIdentifier,
            serverName: serverName ?? "",
            sections: sections,
            section: section,
            albums: albums,
            artists: artists,
            favorites: favorites
        )
        try? await offline.save(snapshot)
        await offline.setFavorites(favorites, server: library.serverIdentifier, sources: library.trackSource)
        downloads.refresh()
    }

    // MARK: - Downloads

    /// Re-enqueues every pinned track not yet on disk. Called on connect
    /// and on foreground, since nothing survives the app being suspended.
    func resumeDownloads() async {
        guard let library, !library.isOffline else { return }
        await offline.resume(server: library.serverIdentifier, sources: library.trackSource)
        downloads.refresh()
    }

    var isFavoritesPinned: Bool { downloads.favoritesPinned }

    /// Turns the favorites pin on or off. On enable, the current favorites
    /// are fetched and pinned; on disable their files go back to the cache.
    func setFavoritesPinned(_ enabled: Bool) async {
        guard let library, !library.isOffline, let section = selectedSection else { return }
        let server = library.serverIdentifier
        await offline.setFavoritesPinned(enabled, server: server)
        if enabled, let favorites = try? await library.favoriteTracks(inSection: section.key) {
            await offline.setFavorites(favorites, server: server, sources: library.trackSource)
        }
        downloads.refresh()
    }

    /// Reconciles the favorites group with the server after a connect,
    /// which also catches hearts set from other clients.
    private func syncFavoritesPin() async {
        guard let library, !library.isOffline, let section = selectedSection,
              await offline.favoritesPinned(server: library.serverIdentifier),
              let favorites = try? await library.favoriteTracks(inSection: section.key)
        else { return }
        await offline.setFavorites(favorites, server: library.serverIdentifier, sources: library.trackSource)
        downloads.refresh()
    }

    func selectSection(_ section: PlexSection) {
        selectedSection = section
        UserDefaults.standard.set(section.key, forKey: Self.sectionDefaultsKey)
    }

    /// Returns to the picker so a different library can be chosen.
    func clearSectionChoice() {
        selectedSection = nil
        UserDefaults.standard.removeObject(forKey: Self.sectionDefaultsKey)
    }

    // MARK: - Listeners

    func addListener(name: String) -> Listener {
        let listener = roster.add(name: name, paletteSize: ListenerPalette.colors.count)
        saveRoster()
        return listener
    }

    func removeListener(_ id: Listener.ID) {
        roster.remove(id)
        saveRoster()
    }

    func renameListener(_ id: Listener.ID, name: String) {
        roster.update(id) { $0.name = name }
        saveRoster()
    }

    func setListenerColor(_ id: Listener.ID, index: Int) {
        roster.update(id) { $0.colorIndex = index }
        saveRoster()
    }

    func toggleListening(_ id: Listener.ID) {
        roster.toggleActive(id)
        saveRoster()
    }

    func toggleVeto(artistKey: String, for id: Listener.ID) {
        roster.toggleVeto(artistKey: artistKey, for: id)
        saveRoster()
    }

    private static func loadRoster() -> ListenerRoster {
        guard let data = UserDefaults.standard.data(forKey: rosterDefaultsKey),
              let roster = try? JSONDecoder().decode(ListenerRoster.self, from: data)
        else { return ListenerRoster() }
        return roster
    }

    private func saveRoster() {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        UserDefaults.standard.set(data, forKey: Self.rosterDefaultsKey)
    }

    /// Puts two listeners on an empty roster so the chips show up in a
    /// simulator without tapping through setup. The value is an artist
    /// ratingKey Laura vetoes, so the hidden line and the album header can
    /// be checked too; `1` seeds without a veto. Compiled out of release.
    private func seedDevelopmentListeners() {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS"],
              !value.isEmpty, roster.listeners.isEmpty else { return }
        let laura = addListener(name: "Laura")
        _ = addListener(name: "Kids")
        toggleListening(laura.id)
        if value != "1" { toggleVeto(artistKey: value, for: laura.id) }
        #endif
    }

    // MARK: - Favorites

    func isFavorite(_ track: PlexTrack) -> Bool {
        favoriteOverrides[track.ratingKey] ?? track.isFavorite
    }

    /// Flips the heart optimistically and reverts if the server refuses.
    /// Hearts are read-only offline: a queued toggle would need an outbox,
    /// and the favorites pin reconciles from the server on reconnect anyway.
    func toggleFavorite(_ track: PlexTrack) async {
        guard let library, !library.isOffline else { return }
        let previous = favoriteOverrides[track.ratingKey]
        let favorite = !isFavorite(track)
        favoriteOverrides[track.ratingKey] = favorite
        do {
            try await library.setFavorite(track.ratingKey, favorite)
        } catch {
            favoriteOverrides[track.ratingKey] = previous
            errorMessage = error.localizedDescription
            return
        }
        // Keep the pinned favorites group in step without a full refetch.
        let server = library.serverIdentifier
        guard await offline.favoritesPinned(server: server) else { return }
        var group = await offline.favoriteTracks(server: server).filter { $0.ratingKey != track.ratingKey }
        if favorite { group.append(track) }
        await offline.setFavorites(group, server: server, sources: library.trackSource)
        downloads.refresh()
    }

    /// Works offline too: only the keychain is involved. Everything pinned
    /// or snapshotted goes with the account.
    func signOut() async {
        guard let auth else { return }
        do {
            try await auth.signOut()
            token = nil
            library = nil
            serverName = nil
            sections = []
            selectedSection = nil
            favoriteOverrides = [:]
            state = .signedOut
            await offline.clear()
            downloads.attach(server: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
