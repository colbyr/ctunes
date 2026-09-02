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
    }

    private(set) var state: State = .loading
    var errorMessage: String?

    /// Set once a server has been reached; the browse views read it.
    private(set) var library: PlexLibrary?
    private(set) var serverName: String?

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

    private var auth: PlexAuth?
    private var client: PlexClient?
    private var token: String?

    /// ASWebAuthenticationSession requires a callback scheme, but Plex never
    /// redirects to one: forwardUrl is ignored for a custom scheme and the
    /// browser lands on watch.plex.tv instead. The sheet is dismissed by
    /// cancelling its task once polling sees the token.
    private static let callbackScheme = "ctunes"

    init() {
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

    /// Finds a reachable server and opens the library on it.
    func connect() async {
        guard let client, let token else { return }
        state = .connecting
        do {
            let server = try await PlexServerDirectory(client: client).selectServer(token: token)
            let library = PlexLibrary(client: client, server: server, token: token)
            self.library = library
            serverName = server.name

            sections = try await library.musicSections()
            let saved = UserDefaults.standard.string(forKey: Self.sectionDefaultsKey)
            selectedSection = sections.first { $0.key == saved } ?? sections.first.flatMap {
                sections.count == 1 ? $0 : nil
            }
            state = .signedIn
        } catch {
            errorMessage = error.localizedDescription
            state = .connectFailed
        }
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
    func toggleFavorite(_ track: PlexTrack) async {
        guard let library else { return }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
