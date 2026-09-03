import Foundation

/// The plex.tv PIN link flow.
///
/// Preferred over posting credentials because it survives two-factor auth and
/// never puts the user's password in our process. The resulting token is
/// identical either way.
///
///   1. `requestPin()` mints a short code
///   2. send the user to `authURL(for:)` in a browser
///   3. `waitForAuthorization(pin:)` polls until they approve it
public actor PlexAuth {
    static let tokenKey = "auth-token"

    private let client: PlexClient
    private let store: any SecretStore

    public init(client: PlexClient, store: any SecretStore = KeychainStore.standard) {
        self.client = client
        self.store = store
    }

    // MARK: - Stored token

    public func storedToken() throws -> String? {
        try store.string(for: Self.tokenKey)
    }

    public func signOut() throws {
        try store.remove(for: Self.tokenKey)
    }

    // MARK: - PIN flow

    public func requestPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=true")!
        let request = client.request("POST", url: url)
        return try await client.decode(PlexPin.self, from: request)
    }

    /// The page the user approves the device on. Params live in the URL
    /// fragment, not the query string.
    public func authURL(for pin: PlexPin, forwardURL: String? = nil) -> URL {
        let identity = client.identity
        var params = [
            "clientID": identity.clientIdentifier,
            "code": pin.code,
            "context[device][product]": identity.product,
        ]
        if let forwardURL {
            params["forwardUrl"] = forwardURL
        }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        let fragment = params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return URL(string: "https://app.plex.tv/auth#?\(fragment)")!
    }

    public func checkPin(_ id: Int) async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        return try await client.get(PlexPin.self, url: url)
    }

    /// Polls until the user approves the PIN, then persists the token.
    ///
    /// - Throws: `PlexError.authorizationTimedOut` if `timeout` elapses first.
    public func waitForAuthorization(
        pin: PlexPin,
        timeout: Duration = .seconds(120),
        pollInterval: Duration = .seconds(1),
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) async throws -> String {
        let deadline = now().advanced(by: timeout)

        while now() < deadline {
            let checked = try await checkPin(pin.id)
            if let token = checked.authToken, !token.isEmpty {
                try store.set(token, for: Self.tokenKey)
                return token
            }
            try await Task.sleep(for: pollInterval)
        }
        throw PlexError.authorizationTimedOut
    }
}
