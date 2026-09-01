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

    /// Scheme Plex forwards back to once the device is approved, which is what
    /// lets the browser sheet dismiss itself instead of stranding the user.
    private static let callbackScheme = "ctunes"
    private static let forwardURL = "ctunes://auth"

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

            let url = await auth.authURL(for: pin, forwardURL: Self.forwardURL)

            var userCancelled = false
            do {
                _ = try await session.authenticate(
                    using: url,
                    callbackURLScheme: Self.callbackScheme
                )
            } catch ASWebAuthenticationSessionError.canceledLogin {
                userCancelled = true
            }

            // Closing the sheet doesn't always mean refusal: if forwardUrl
            // fails to fire, the user approves and then dismisses manually.
            // Check once before believing the cancel.
            if userCancelled {
                let checked = try await auth.checkPin(pin.id)
                guard checked.isAuthorized else {
                    state = .signedOut
                    return
                }
            }

            token = try await auth.waitForAuthorization(pin: pin, timeout: .seconds(30))
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
