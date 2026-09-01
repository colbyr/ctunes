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

    private static let sectionDefaultsKey = "selected-section-key"

    private var auth: PlexAuth?
    private var client: PlexClient?
    private var token: String?

    /// ASWebAuthenticationSession requires a callback scheme, but Plex never
    /// redirects to one: forwardUrl is ignored for a custom scheme and the
    /// browser lands on watch.plex.tv instead. The sheet is dismissed by
    /// cancelling its task once polling sees the token.
    private static let callbackScheme = "ctunes"

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

    func signOut() async {
        guard let auth else { return }
        do {
            try await auth.signOut()
            token = nil
            library = nil
            serverName = nil
            sections = []
            selectedSection = nil
            state = .signedOut
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
