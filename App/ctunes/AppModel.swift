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
        case signedIn
    }

    private(set) var state: State = .loading
    var errorMessage: String?

    private var auth: PlexAuth?
    private var token: String?

    /// ASWebAuthenticationSession requires a callback scheme, but Plex never
    /// redirects to one: forwardUrl is ignored for a custom scheme and the
    /// browser lands on watch.plex.tv instead. The sheet is dismissed by
    /// cancelling its task once polling sees the token.
    private static let callbackScheme = "ctunes"

    func bootstrap() async {
        do {
            let identity = try PlexIdentity.persistent()
            let auth = PlexAuth(client: PlexClient(identity: identity))
            self.auth = auth

            if let existing = try await auth.storedToken() {
                token = existing
                state = .signedIn
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
            state = .signedIn
        } catch {
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func signOut() async {
        guard let auth else { return }
        do {
            try await auth.signOut()
            token = nil
            state = .signedOut
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
