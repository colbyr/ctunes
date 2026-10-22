import AuthenticationServices
import Observation
import PlexKit
import SwiftUI
import os

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
        /// A library is open, from the saved copies at once and from the
        /// server as it answers. Whether it does is `connection`, not a
        /// state: the stack and the queue outlive every change of it.
        case signedIn
    }

    private(set) var state: State = .loading
    var errorMessage: String?

    /// The one library for the server and section, open from disk as soon
    /// as both are known and kept across every connection change; the
    /// browse views read it. Replaced only when the account, server or
    /// section changes.
    private(set) var library: (any LibrarySource)?
    private var cached: CachedLibrary?
    /// Bumped whenever `library` is replaced.
    private(set) var libraryGeneration = 0
    /// Bumped as every saved copy lands and with the generation: what the
    /// screens key their tasks on, so a page reads again (from disk, the
    /// library's floor keeping the server out of it) when its lists change.
    private(set) var libraryRevision = 0
    private var libraryFollower: Task<Void, Never>?
    private(set) var serverName: String?

    /// Whether the server answers, and the finding of it again. The
    /// screens read `connection` for the banner and the dimming.
    private let monitor = ConnectionMonitor()
    var connection: ConnectionMonitor.Connection { monitor.connection }
    var isConnected: Bool { monitor.isConnected }
    /// A search that has run long enough to say so on screen.
    var searchingSlow: Bool { monitor.searchingSlow }

    /// Pinned albums and their download state, for the views.
    let downloads: Downloads
    private let offline: OfflineStore
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ctunes", category: "Connection")

    /// Music libraries on the server, and the one being browsed. A server can
    /// expose several (audiobooks also report type "artist"), so the choice is
    /// remembered rather than asked for on every launch.
    private(set) var sections: [PlexSection] = []
    /// Set after `library` whenever either changes, so `libraryID` is
    /// always the pair and the state filed under it follows.
    private(set) var selectedSection: PlexSection? {
        didSet { libraryChanged() }
    }

    /// The library open, once a section is chosen. What is kept per
    /// library (the shortcuts, the listeners' vetoes, the favorites group,
    /// the mix builder's picks) is read and written under it.
    private(set) var libraryID: LibraryID?

    /// The signed-in plex.tv account's `uuid`, kept in the keychain beside
    /// the token. Two accounts can open the same server and section, so
    /// what a person keeps (the listeners, the shortcuts, the mix
    /// builder's picks, recent searches, the section chosen) is filed
    /// under it as well; nil signed out, and before the first lookup.
    private(set) var account: String? {
        didSet {
            guard account != oldValue else { return }
            accountChanged()
        }
    }

    /// The `UserDefaults` or iCloud key for what this account keeps about
    /// the open library: `<prefix>.<account>.<server>.<section>`. Nil
    /// until both are known.
    func storageKey(_ prefix: String) -> String? {
        guard let account, let libraryID else { return nil }
        return libraryID.key("\(prefix).\(account)")
    }

    /// The section's playlists, fetched with the browse root's other
    /// requests and after every edit, so the Add to Playlist submenu is
    /// synchronous and every screen agrees on the names.
    private(set) var playlists: [PlexPlaylist] = []
    /// Bumped on every playlist write, so a page keyed on it reloads
    /// after an add from another screen's menu.
    private(set) var playlistGeneration = 0

    /// Hearts toggled in this session, keyed by ratingKey. Tracks are
    /// immutable values fetched per screen and also held in the player's
    /// queue, so a toggle is layered over them here rather than pushed into
    /// every copy.
    private var favoriteOverrides: [String: Bool] = [:]

    /// People who share the phone and the artists they'd rather skip. Never
    /// in Plex, but per account (`listeners.<account>`), since another
    /// account is another household: empty while signed out, back on
    /// signing in again. The listeners live in the iCloud key-value store
    /// so every device on the Apple ID shares them; who is currently
    /// listening stays on this device, since the phone in the car and the
    /// Mac at home differ. `UserDefaults` keeps a full copy so launch never
    /// waits on iCloud.
    private(set) var roster = ListenerRoster()

    /// The play buttons at the top of the Music screen: mixes saved from
    /// the builder, in their order. Per library, since every pick is that
    /// library's content: one list per account and library under
    /// `shortcuts.<account>.<server>.<section>` in iCloud, last writer
    /// wins, a copy in `UserDefaults` under the same key so launch never
    /// waits. Empty until a library is open. A library's first open
    /// starts with Shuffle Favorites; an emptied list stays empty.
    private(set) var shortcuts: [SavedMix] = []

    /// Per account and server: `selected-section-key.<account>.<server>`.
    /// Section keys are small numbers that every server reuses.
    private static let sectionDefaultsKey = "selected-section-key"
    /// `listeners.<account>`, in `UserDefaults` and iCloud alike.
    private static let listenersKey = "listeners"
    private static let shortcutsKey = "shortcuts"
    private static let serverDefaultsKey = "last-server-id"

    private func sectionKey(server: String) -> String {
        "\(Self.sectionDefaultsKey).\(account ?? "").\(server)"
    }

    private var rosterKey: String? {
        account.map { "\(Self.listenersKey).\($0)" }
    }

    private var auth: PlexAuth?
    private var client: PlexClient?
    private var token: String?
    /// The last server's own `accessToken`, kept for offline artwork URLs.
    private var serverToken: String?

    /// ASWebAuthenticationSession requires a callback scheme, but Plex never
    /// redirects to one: forwardUrl is ignored for a custom scheme and the
    /// browser lands on watch.plex.tv instead. The sheet is dismissed by
    /// cancelling its task once polling sees the token.
    private static let callbackScheme = "ctunes"

    init(offline: OfflineStore, cache: TrackCache) {
        self.offline = offline
        downloads = Downloads(store: offline, cache: cache)
        monitor.reconnect = { [weak self] force in await self?.attemptConnect(tapped: force, patience: .zero) }
        followMonitor()
        startCloudSync()
        // A new download quality re-asks every pin for what it still wants.
        downloads.pinsChanged = { [weak self] in await self?.resumeDownloads() }
    }

    func bootstrap() async {
        do {
            let identity = try PlexIdentity.persistent()
            let client = PlexClient(identity: identity)
            let auth = PlexAuth(client: client)
            self.client = client
            self.auth = auth
            monitor.start(client: client, token: "")

            let stored = try await auth.storedToken()
            if let existing = Self.developmentToken() ?? stored {
                token = existing
                monitor.start(client: client, token: existing)
                // A development token may be another account's than the
                // one the keychain last looked up.
                var found: String?
                if Self.developmentToken() != nil {
                    found = try? await auth.lookUpAccount(token: existing)
                }
                if found == nil {
                    found = try? await auth.storedAccount()
                }
                account = found
                if let server = UserDefaults.standard.string(forKey: Self.serverDefaultsKey) {
                    serverToken = try? await auth.serverToken(for: server)
                }
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
            account = try? await auth.lookUpAccount(token: found)
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

    /// Opens the last library from disk and finds the server behind it;
    /// without a saved library the connecting screen shows until one
    /// answers. Nothing answering leaves the library open unreachable,
    /// so the app is still usable with the server off.
    func connect() async {
        if case .unreachable = connection {
            await monitor.tryAgain(force: true)
            return
        }
        // The last library opens from disk at once while discovery runs
        // behind it, with the patience to ride out a network still coming
        // up; a first launch has nothing to show and waits, less long.
        if await openSavedLibrary() {
            state = .signedIn
            await attemptConnect(tapped: false, patience: .seconds(20))
        } else {
            state = .connecting
            await attemptConnect(tapped: false, patience: .seconds(10))
        }
    }

    /// The banner's "Try again" (forced) and the scene coming back:
    /// throttled unless forced, and never through `.connecting`.
    func reconnect(force: Bool = false) async {
        await monitor.tryAgain(force: force)
    }

    private func attemptConnect(tapped: Bool, patience: Duration) async {
        guard let token else { return }
        monitor.searching()
        do {
            if ConnectionMonitor.forceOffline, !tapped { throw PlexError.noServerReachable }
            let server = try await monitor.discover(patience: patience)
            // Signed in while plex.tv was away: discovery just reached it.
            if account == nil, let auth {
                account = try? await auth.lookUpAccount(token: token)
            }
            guard let connection = monitor.connection(for: server) else { return }
            let sections = try await connection.musicSections()
            let record = ServerRecord(name: server.name, sections: sections, baseURL: server.baseURL)
            try? await offline.saveServer(record, server: server.machineIdentifier)
            UserDefaults.standard.set(server.machineIdentifier, forKey: Self.serverDefaultsKey)
            rememberServerToken(server)
            serverName = server.name
            self.sections = sections
            let saved = UserDefaults.standard.string(forKey: sectionKey(server: server.machineIdentifier))
            let section = sections.first { $0.key == saved } ?? sections.first.flatMap {
                sections.count == 1 ? $0 : nil
            }
            // The library first, so the connection attaches to it once.
            await openLibrary(server: server.machineIdentifier, section: section, record: record)
            await monitor.connected(server, connection)
            errorMessage = nil
            state = .signedIn
            await resumeDownloads()
            await syncFavoritesPin()
            await syncPlaylistPins()
        } catch {
            errorMessage = error.localizedDescription
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            let opened = state == .signedIn ? true : await openSavedLibrary()
            if opened {
                state = .signedIn
                await monitor.unreachable()
            } else {
                state = .connectFailed
            }
        }
    }

    private func rememberServerToken(_ server: PlexServer) {
        guard let accessToken = server.accessToken, accessToken != serverToken else { return }
        serverToken = accessToken
        let auth = auth
        Task { try? await auth?.setServerToken(accessToken, for: server.machineIdentifier) }
    }

    /// The monitor's state, mirrored where the app keeps a copy: the
    /// downloads read as waiting with no server, and a server that
    /// answered somewhere new is named and its token kept.
    private func followMonitor() {
        let monitor = monitor
        Task { @MainActor [weak self] in
            for await connection in Observations({ monitor.connection }) {
                guard let self else { return }
                if case .connected(let server) = connection {
                    serverName = server.name
                    rememberServerToken(server)
                }
                downloads.connected = monitor.isConnected
            }
        }
    }

    /// The scene coming to the front while signed in: a reason to look
    /// for the server, and to pick the downloads up again.
    func sceneActivated() async {
        guard state == .signedIn else { return }
        await monitor.activated()
        if isConnected { await resumeDownloads() }
    }

    // MARK: - The library

    /// Opens the last library from what was saved, with no network: the
    /// server record and the section chosen, or the only one. False when
    /// nothing was saved, which is a first launch.
    private func openSavedLibrary() async -> Bool {
        if cached != nil { return true }
        guard let server = UserDefaults.standard.string(forKey: Self.serverDefaultsKey),
              let record = await offline.server(server)
        else { return false }
        let saved = UserDefaults.standard.string(forKey: sectionKey(server: server))
        guard let section = record.sections.first(where: { $0.key == saved })
            ?? (record.sections.count == 1 ? record.sections.first : nil)
        else { return false }
        serverName = record.name
        sections = record.sections
        await openLibrary(server: server, section: section, record: record)
        return true
    }

    /// The library for the section: the one open when it is the same (a
    /// reconnect attaches the connection to it), a new object when the
    /// server or section changed. No section closes it, and the picker
    /// shows until one is chosen.
    private func openLibrary(server: String, section: PlexSection?, record: ServerRecord?) async {
        guard let section else {
            closeLibrary()
            selectedSection = nil
            return
        }
        let id = LibraryID(server: server, section: section.key)
        if let cached, cached.id == id {
            selectedSection = section
            if let record { await cached.updateRecord(record) }
            await monitor.watch(cached)
            return
        }
        closeLibrary()
        let opened = CachedLibrary(id: id, store: offline, token: serverToken ?? token, record: record)
        await opened.onConnectionFailure { [weak self] error, _ in
            await self?.connectionLost(error)
        }
        cached = opened
        library = opened
        selectedSection = section
        follow(opened)
        await monitor.watch(opened)
        libraryGeneration += 1
        libraryRevision += 1
        downloads.attach(server: id.server)
        playlists = await offline.load([PlexPlaylist].self, for: .playlists, server: id.server, section: id.section) ?? []
        if let albums = await offline.load([PlexAlbum].self, for: .albums, server: id.server, section: id.section) {
            downloads.setAlbums(albums)
        }
    }

    private func closeLibrary() {
        libraryFollower?.cancel()
        libraryFollower = nil
        cached = nil
        library = nil
        Task { await monitor.watch(nil) }
    }

    /// Mirrors the library's changes: the revision the screens key on,
    /// and the lists the app keeps beside the library (the playlists for
    /// the menus, the albums for the download badges, the favorites and
    /// the pinned playlists reconciled against their files).
    private func follow(_ library: CachedLibrary) {
        libraryFollower?.cancel()
        libraryFollower = Task { [weak self] in
            for await key in library.changes {
                guard let self, self.cached === library else { return }
                self.libraryRevision += 1
                await self.libraryDidSave(key)
            }
        }
    }

    private func libraryDidSave(_ key: LibraryKey) async {
        guard let cached, let section = selectedSection else { return }
        let server = cached.id.server
        switch key {
        case .albums:
            if let albums = await offline.load([PlexAlbum].self, for: .albums, server: server, section: section.key) {
                downloads.setAlbums(albums)
            }
        case .playlists:
            await loadPlaylists()
        case .favorites:
            await syncFavoritesPin()
        case .playlistItems(let ratingKey):
            guard await offline.playlistPinned(ratingKey, server: server),
                  let items = await offline.items(inPlaylist: ratingKey, server: server)
            else { return }
            await offline.setPlaylistItems(items, inPlaylist: ratingKey, server: server, sources: downloads.sources(cached))
            downloads.refresh()
        case .artists, .history, .albumTracks, .artistAlbums, .artistTracks:
            break
        }
    }

    /// The server the library is on, or the connection's before a section
    /// is chosen.
    private var currentServer: String? {
        cached?.id.server ?? monitor.current?.serverIdentifier
    }

    /// Whether launch has settled: a library is open and the server has
    /// answered or been given up on, or the app knows it can't have one.
    /// A search still out is unsettled on purpose: an intent that fires
    /// with the phone locked should get the server, not the saved copy,
    /// when the server is a second away.
    var isSettled: Bool {
        switch state {
        case .loading, .connecting: return false
        case .signedOut, .linking, .connectFailed: return true
        case .signedIn:
            if case .searching = connection { return false }
            return true
        }
    }

    /// Waits for launch to settle, so an intent that fired with no window
    /// and `bootstrap` still running has a library to play from. Returns
    /// the state it settled in, or the current one after `timeout`: a
    /// search still out then plays from what is saved, which is what the
    /// browse root would show.
    func ready(timeout: Duration = .seconds(12)) async -> State {
        // Polled rather than observed: an `Observations` stream raced
        // against a sleep in a task group hits a Swift 6 isolation-checker
        // bug, and only an intent ever waits here, for seconds at most.
        let deadline = ContinuousClock.now + timeout
        while !isSettled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return state
    }

    // MARK: - Connection

    /// A fetch or a stream that failed on the transport: the monitor
    /// probes and moves or detaches the library's connection. True when
    /// a server answered, so the caller can retry what failed.
    @discardableResult
    func connectionLost(_ error: Error) async -> Bool {
        guard state == .signedIn else { return false }
        return await monitor.failed(error)
    }

    // MARK: - Playlists

    /// The section's playlists from the library: its saved copy, the
    /// server behind it. A miss it can't fetch keeps the old list.
    func loadPlaylists() async {
        guard let library, let section = selectedSection else { return }
        guard let fetched = try? await library.playlists(inSection: section.key) else { return }
        if fetched != playlists { playlists = fetched }
    }

    /// The writes: each calls the server through the library, which asks
    /// for the list again, and bumps the generation so every page agrees.
    /// A connection failure runs the usual rediscovery; any failure
    /// returns false so the caller reverts what it applied optimistically.
    /// All refused with no server, like hearts.
    func createPlaylist(title: String, tracks: [PlexTrack]) async -> PlexPlaylist? {
        guard let library, library.isConnected else { return nil }
        do {
            let created = try await library.createPlaylist(title: title, trackKeys: tracks.map(\.ratingKey))
            await playlistsChanged()
            return created
        } catch {
            await playlistWriteFailed(error)
            return nil
        }
    }

    /// Appends the tracks and returns how many were new to the playlist,
    /// or nil on failure. The server drops what is already there.
    func add(_ tracks: [PlexTrack], to playlist: PlexPlaylist) async -> Int? {
        guard let library, library.isConnected else { return nil }
        do {
            let added = try await library.add(trackKeys: tracks.map(\.ratingKey), toPlaylist: playlist.ratingKey)
            await playlistsChanged()
            return added
        } catch {
            await playlistWriteFailed(error)
            return nil
        }
    }

    func remove(_ item: PlaylistItem, from playlist: PlexPlaylist) async -> Bool {
        guard let library, library.isConnected, let id = item.playlistItemID else { return false }
        do {
            try await library.remove(item: id, fromPlaylist: playlist.ratingKey)
            await playlistsChanged()
            return true
        } catch {
            await playlistWriteFailed(error)
            return false
        }
    }

    /// Puts the item after `after`, or at the top with none.
    func move(_ item: PlaylistItem, after: PlaylistItem?, in playlist: PlexPlaylist) async -> Bool {
        guard let library, library.isConnected, let id = item.playlistItemID else { return false }
        do {
            try await library.move(item: id, after: after?.playlistItemID, inPlaylist: playlist.ratingKey)
            await playlistsChanged()
            return true
        } catch {
            await playlistWriteFailed(error)
            return false
        }
    }

    func rename(_ playlist: PlexPlaylist, to title: String) async -> Bool {
        guard let library, library.isConnected else { return false }
        do {
            try await library.renamePlaylist(playlist.ratingKey, title: title)
            await playlistsChanged()
            return true
        } catch {
            await playlistWriteFailed(error)
            return false
        }
    }

    /// The one irreversible action in the app: the caller confirms first.
    func delete(_ playlist: PlexPlaylist) async -> Bool {
        guard let library, library.isConnected else { return false }
        do {
            try await library.deletePlaylist(playlist.ratingKey)
            if await offline.playlistPinned(playlist.ratingKey, server: library.serverIdentifier) {
                await offline.unpinPlaylist(playlist.ratingKey, server: library.serverIdentifier)
                downloads.refresh()
            }
            await playlistsChanged()
            return true
        } catch {
            await playlistWriteFailed(error)
            return false
        }
    }

    private func playlistsChanged() async {
        await loadPlaylists()
        playlistGeneration += 1
    }

    private func playlistWriteFailed(_ error: Error) async {
        errorMessage = error.localizedDescription
        await connectionLost(error)
    }

    /// Keeps the playlist offline, or stops: its items are fetched and
    /// pinned as a group beside the favorites, never as part of the
    /// artist/album/track tree, so removing it narrows nothing else.
    func setPlaylistPinned(_ playlist: PlexPlaylist, _ enabled: Bool) async {
        guard let library, library.isConnected else { return }
        let server = library.serverIdentifier
        if enabled {
            guard let items = try? await library.items(inPlaylist: playlist.ratingKey) else { return }
            await offline.pinPlaylist(playlist, items: items, server: server,
                                      art: { library.artworkURL($0, size: 600) }, sources: downloads.sources(library))
        } else {
            await offline.unpinPlaylist(playlist.ratingKey, server: server)
        }
        downloads.refresh()
    }

    /// Reconciles every pinned playlist with the server after a connect,
    /// which catches edits made from other clients; one gone from the
    /// server is unpinned.
    private func syncPlaylistPins() async {
        guard let library, library.isConnected else { return }
        let server = library.serverIdentifier
        let pinned = await offline.inventory(server: server).playlists
        guard !pinned.isEmpty else { return }
        await loadPlaylists()
        let listed = Set(playlists.map(\.ratingKey))
        for pin in pinned {
            if !playlists.isEmpty, !listed.contains(pin.id) {
                await offline.unpinPlaylist(pin.id, server: server)
                continue
            }
            guard let items = try? await library.items(inPlaylist: pin.id) else { continue }
            await offline.setPlaylistItems(items, inPlaylist: pin.id, server: server, sources: downloads.sources(library))
        }
        downloads.refresh()
    }

    // MARK: - Downloads

    /// Re-enqueues every pinned track not yet on disk. Called on connect
    /// and on foreground, since nothing survives the app being suspended.
    func resumeDownloads() async {
        guard let library, library.isConnected else { return }
        await offline.resume(server: library.serverIdentifier, sources: downloads.sources(library))
        downloads.refresh()
    }

    /// Pins every album of the artist: their album list and every track of
    /// theirs in one fetch each, so the store can file the tracks under
    /// the albums. A fetch failure pins nothing. Returns whether the pin
    /// was made.
    @discardableResult
    func downloadArtist(key: String, title: String) async -> Bool {
        guard let library, library.isConnected, let section = selectedSection else { return false }
        do {
            async let albums = library.albums(forArtist: key, inSection: section.key)
            async let tracks = library.tracks(forArtist: key, inSection: section.key)
            async let artists = library.artists(inSection: section.key)
            let sorted = AlbumView.artist.sorted(try await albums)
            let list = try await tracks
            guard !sorted.isEmpty, !list.isEmpty else { return false }
            let thumb = (try? await artists)?.first { $0.ratingKey == key }?.thumb
            downloads.pinArtist(key: key, title: title, thumb: thumb, albums: sorted, tracks: list,
                                section: section.key, library: library)
            return true
        } catch {
            return false
        }
    }

    var isFavoritesPinned: Bool { downloads.favoritesPinned }

    /// Turns the favorites pin on or off. On enable, the current favorites
    /// are fetched and pinned; on disable their files go back to the cache.
    func setFavoritesPinned(_ enabled: Bool) async {
        guard let library, library.isConnected, let section = selectedSection else { return }
        let server = library.serverIdentifier
        await offline.setFavoritesPinned(enabled, server: server, section: section.key)
        if enabled, let favorites = try? await library.favoriteTracks(inSection: section.key) {
            await offline.setFavorites(favorites, server: server, section: section.key, sources: downloads.sources(library))
        }
        downloads.refresh()
    }

    /// Reconciles the favorites group with the list as the library has it:
    /// after a connect, and whenever the saved list changes, which is how
    /// a heart set here or from another client reaches the files.
    private func syncFavoritesPin() async {
        guard let library, library.isConnected, let section = selectedSection,
              await offline.favoritesPinned(server: library.serverIdentifier, section: section.key),
              let favorites = try? await library.favoriteTracks(inSection: section.key)
        else { return }
        await offline.setFavorites(favorites, server: library.serverIdentifier, section: section.key,
                                   sources: downloads.sources(library))
        downloads.refresh()
    }

    func selectSection(_ section: PlexSection) {
        guard let server = currentServer else { return }
        UserDefaults.standard.set(section.key, forKey: sectionKey(server: server))
        selectedSection = section
        Task { await openLibrary(server: server, section: section, record: await offline.server(server)) }
    }

    /// Returns to the picker so a different library can be chosen.
    func clearSectionChoice() {
        guard let server = currentServer else { return }
        UserDefaults.standard.removeObject(forKey: sectionKey(server: server))
        closeLibrary()
        selectedSection = nil
    }

    /// Files what is kept per library under the one now open: the
    /// roster answers with its vetoes, the shortcuts are its list, the
    /// downloads show its favorites.
    private func libraryChanged(force: Bool = false) {
        let id = selectedSection.flatMap { section in
            library.map { LibraryID(server: $0.serverIdentifier, section: section.key) }
        }
        guard force || id != libraryID else { return }
        libraryID = id
        roster.library = id
        downloads.section = id?.section
        loadShortcuts()
        seedDevelopmentVetoes()
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

    func toggleVeto(_ veto: Veto, for id: Listener.ID) {
        roster.toggleVeto(veto, for: id)
        saveRoster()
    }

    func removeVeto(_ target: VetoTarget, for id: Listener.ID) {
        roster.removeVeto(target, for: id)
        saveRoster()
    }

    /// The account's roster from this device's copy, else the starter,
    /// which then seeds iCloud unless iCloud already holds one; signed
    /// out, none. Then what is kept per library, read again under the
    /// new account.
    private func accountChanged() {
        if let key = rosterKey {
            if let data = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode(ListenerRoster.self, from: data) {
                roster = saved
            } else {
                roster = .starter(paletteSize: ListenerPalette.colors.count)
            }
            roster.library = libraryID
            if NSUbiquitousKeyValueStore.default.data(forKey: key) == nil {
                pushListenersToCloud()
            }
            pullFromCloud()
            seedDevelopmentListeners()
        } else {
            roster = ListenerRoster(library: libraryID)
        }
        libraryChanged(force: true)
    }

    private func saveRoster() {
        guard let key = rosterKey else { return }
        if let data = try? JSONEncoder().encode(roster) {
            UserDefaults.standard.set(data, forKey: key)
        }
        pushListenersToCloud()
    }

    // MARK: - Shortcuts

    /// Saves a mix at the end of the row.
    @discardableResult
    func addShortcut(name: String, picks: [MixPick], style: PlayStyle) -> SavedMix {
        let mix = SavedMix(name: name, picks: picks, style: style)
        shortcuts.append(mix)
        saveShortcuts()
        return mix
    }

    func removeShortcut(_ id: SavedMix.ID) {
        shortcuts.removeAll { $0.id == id }
        saveShortcuts()
    }

    func moveShortcuts(from source: IndexSet, to destination: Int) {
        shortcuts.move(fromOffsets: source, toOffset: destination)
        saveShortcuts()
    }

    /// Any of a saved mix's parts: its name, its picks (re-saved from the
    /// builder), how it plays.
    func updateShortcut(_ id: SavedMix.ID, _ change: (inout SavedMix) -> Void) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        change(&shortcuts[index])
        saveShortcuts()
    }

    func shortcut(_ id: SavedMix.ID) -> SavedMix? {
        shortcuts.first { $0.id == id }
    }

    /// The open library's list: iCloud's when it has one, else this
    /// device's copy, else the starter, which then seeds iCloud.
    private func loadShortcuts() {
        guard let key = storageKey(Self.shortcutsKey) else {
            shortcuts = []
            return
        }
        if let cloud: [SavedMix] = Self.cloudValue(key) {
            shortcuts = cloud
        } else if let data = UserDefaults.standard.data(forKey: key),
                  let saved = try? JSONDecoder().decode([SavedMix].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = [.starter]
        }
        saveShortcuts()
    }

    private func saveShortcuts() {
        guard let key = storageKey(Self.shortcutsKey) else { return }
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: key)
        }
        Self.push(shortcuts, toCloudKey: key)
    }

    // MARK: Cloud sync

    /// Adopts whatever iCloud already holds, seeds it from this device when
    /// it holds nothing, and follows later changes from other devices. The
    /// store is a local cache that iCloud syncs behind the scenes, so none
    /// of this waits on the network. The observer is never removed: one
    /// model lives as long as the process.
    private func startCloudSync() {
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pullFromCloud() }
        }
        store.synchronize()
    }

    /// Called when the scene comes forward so a change made on another
    /// device while this one was in the background lands right away rather
    /// than on iCloud's own schedule.
    func refreshFromCloud() {
        NSUbiquitousKeyValueStore.default.synchronize()
        pullFromCloud()
    }

    private func pullFromCloud() {
        if let key = rosterKey,
           let listeners: [Listener] = Self.cloudValue(key), listeners != roster.allListeners {
            roster.replaceListeners(with: listeners)
            if let data = try? JSONEncoder().encode(roster) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        if let key = storageKey(Self.shortcutsKey),
           let shortcuts: [SavedMix] = Self.cloudValue(key), shortcuts != self.shortcuts {
            self.shortcuts = shortcuts
            if let data = try? JSONEncoder().encode(shortcuts) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// Only the listeners go up, with every library's vetoes; the active
    /// set is this device's alone.
    private func pushListenersToCloud() {
        guard let key = rosterKey else { return }
        Self.push(roster.allListeners, toCloudKey: key)
    }

    private static func cloudValue<T: Decodable>(_ key: String) -> T? {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Skipped when the store already matches, so a save that changed
    /// nothing iCloud holds (toggling who is listening) doesn't churn it.
    private static func push<T: Codable & Equatable>(_ value: T, toCloudKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if let current: T = cloudValue(key), current == value { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
    }

    /// Puts two listeners on an empty roster so the chips show up in a
    /// simulator without tapping through setup. The value is an artist
    /// ratingKey Laura vetoes, so the hidden line and the album header can
    /// be checked too, or `album:<key>` / `track:<key>` for the narrower
    /// vetoes; `1` seeds without a veto. The vetoes wait for a library to
    /// be filed under (`seedDevelopmentVetoes`). Compiled out of release.
    private func seedDevelopmentListeners() {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS"],
              !value.isEmpty, roster.listeners.count <= 1 else { return }
        let laura = addListener(name: "Laura")
        _ = addListener(name: "Kids")
        toggleListening(laura.id)
        guard value != "1" else { return }
        developmentVetoes = value.split(separator: ",").map(String.init).map { value in
            if value.hasPrefix("album:") {
                Veto(.album(String(value.dropFirst(6))), title: "")
            } else if value.hasPrefix("track:") {
                Veto(.track(String(value.dropFirst(6))), title: "")
            } else {
                Veto(artistKey: value, title: "")
            }
        }
        developmentVetoer = laura.id
        #endif
    }

    @ObservationIgnored private var developmentVetoes: [Veto] = []
    @ObservationIgnored private var developmentVetoer: Listener.ID?

    private func seedDevelopmentVetoes() {
        guard libraryID != nil, let id = developmentVetoer else { return }
        for veto in developmentVetoes { toggleVeto(veto, for: id) }
        developmentVetoes = []
        developmentVetoer = nil
    }

    // MARK: - Favorites

    func isFavorite(_ track: PlexTrack) -> Bool {
        favoriteOverrides[track.ratingKey] ?? track.isFavorite
    }

    /// Flips the heart optimistically and reverts if the server refuses.
    /// Hearts are read-only with no server: a queued toggle would need an
    /// outbox. The library asks for the favorites again after the write,
    /// and the pinned group follows the saved list through `libraryDidSave`.
    func toggleFavorite(_ track: PlexTrack) async {
        guard let library, library.isConnected else { return }
        let previous = favoriteOverrides[track.ratingKey]
        let favorite = !isFavorite(track)
        favoriteOverrides[track.ratingKey] = favorite
        do {
            try await library.setFavorite(track.ratingKey, favorite)
        } catch {
            favoriteOverrides[track.ratingKey] = previous
            errorMessage = error.localizedDescription
        }
    }

    /// Works offline too: only the keychain is involved. Everything pinned
    /// or snapshotted goes with the account.
    func signOut() async {
        guard let auth else { return }
        do {
            try await auth.signOut(server: UserDefaults.standard.string(forKey: Self.serverDefaultsKey))
            token = nil
            serverToken = nil
            monitor.stop()
            closeLibrary()
            serverName = nil
            sections = []
            selectedSection = nil
            playlists = []
            favoriteOverrides = [:]
            state = .signedOut
            await offline.clear()
            account = nil
            downloads.attach(server: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
