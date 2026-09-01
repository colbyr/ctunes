import Foundation
import Testing
@testable import PlexKit

@Suite("PIN link flow")
struct PlexAuthTests {
    let identity = PlexIdentity(clientIdentifier: "TEST-UUID", product: "ctunes")

    private func makeAuth(
        store: any SecretStore = InMemorySecretStore(),
        handler: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response = { _ in
            .json(#"{"id":0,"code":"NONE","authToken":null}"#)
        }
    ) -> PlexAuth {
        PlexAuth(
            client: PlexClient(identity: identity, session: MockURLProtocol.session(handler: handler)),
            store: store
        )
    }

    @Test("requestPin decodes the code and the still-absent token")
    func requestPin() async throws {
        let auth = makeAuth { _ in .json(#"{"id":12345,"code":"ABCD","authToken":null}"#) }

        let pin = try await auth.requestPin()
        #expect(pin.id == 12345)
        #expect(pin.code == "ABCD")
        #expect(pin.authToken == nil)
        #expect(pin.isAuthorized == false)
    }

    @Test("requestPin POSTs with the strong flag")
    func requestPinUsesPost() async throws {
        let seen = Locked<URLRequest?>(nil)
        let auth = makeAuth { request in
            seen.set(request)
            return .json(#"{"id":1,"code":"AAAA","authToken":null}"#)
        }

        _ = try await auth.requestPin()
        let request = try #require(seen.get())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.contains("strong=true") == true)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "TEST-UUID")
    }

    /// Plex reads these from the fragment, not the query string.
    @Test("authURL puts params in the fragment")
    func authURLShape() async {
        let pin = PlexPin(id: 1, code: "WXYZ", authToken: nil)
        let url = await makeAuth().authURL(for: pin)
        let string = url.absoluteString

        #expect(string.hasPrefix("https://app.plex.tv/auth#?"))
        #expect(string.contains("code=WXYZ"))
        #expect(string.contains("clientID=TEST-UUID"))
        // Brackets must be encoded or the page drops the param.
        #expect(string.contains("context%5Bdevice%5D%5Bproduct%5D=ctunes"))
    }

    @Test("authURL carries forwardUrl when given")
    func authURLForward() async {
        let pin = PlexPin(id: 1, code: "WXYZ", authToken: nil)
        let url = await makeAuth().authURL(for: pin, forwardURL: "ctunes://auth")
        #expect(url.absoluteString.contains("forwardUrl=ctunes%3A%2F%2Fauth"))
    }

    @Test("polling returns the token once the user approves, and stores it")
    func waitForAuthorization() async throws {
        let calls = Locked(0)
        let store = InMemorySecretStore()
        let auth = makeAuth(store: store) { _ in
            let n = calls.modify { $0 += 1; return $0 }
            // Unapproved for the first two polls, approved on the third.
            let token = n >= 3 ? "\"tok_secret\"" : "null"
            return .json(#"{"id":1,"code":"AAAA","authToken":\#(token)}"#)
        }

        let token = try await auth.waitForAuthorization(
            pin: PlexPin(id: 1, code: "AAAA", authToken: nil),
            timeout: .seconds(5),
            pollInterval: .milliseconds(1)
        )

        #expect(token == "tok_secret")
        #expect(calls.get() == 3)
        #expect(try store.string(for: "auth-token") == "tok_secret")
    }

    @Test("polling gives up after the timeout")
    func waitTimesOut() async throws {
        let auth = makeAuth { _ in .json(#"{"id":1,"code":"AAAA","authToken":null}"#) }

        await #expect(throws: PlexError.self) {
            try await auth.waitForAuthorization(
                pin: PlexPin(id: 1, code: "AAAA", authToken: nil),
                timeout: .milliseconds(30),
                pollInterval: .milliseconds(1)
            )
        }
    }

    @Test("an unapproved pin leaves nothing in the store")
    func timeoutStoresNothing() async throws {
        let store = InMemorySecretStore()
        let auth = makeAuth(store: store) { _ in .json(#"{"id":1,"code":"A","authToken":null}"#) }

        _ = try? await auth.waitForAuthorization(
            pin: PlexPin(id: 1, code: "A", authToken: nil),
            timeout: .milliseconds(20),
            pollInterval: .milliseconds(1)
        )
        #expect(try store.string(for: "auth-token") == nil)
    }

    @Test("an empty token string is not treated as authorized")
    func emptyTokenIsNotAuthorized() {
        #expect(PlexPin(id: 1, code: "A", authToken: "").isAuthorized == false)
        #expect(PlexPin(id: 1, code: "A", authToken: "t").isAuthorized == true)
    }

    @Test("signOut clears the stored token")
    func signOut() async throws {
        let store = InMemorySecretStore(["auth-token": "tok"])
        let auth = makeAuth(store: store)

        #expect(try await auth.storedToken() == "tok")
        try await auth.signOut()
        #expect(try await auth.storedToken() == nil)
    }

    @Test("an HTTP error surfaces rather than looking like a missing token")
    func httpErrorSurfaces() async {
        let auth = makeAuth { _ in .init(status: 401, body: Data(#"{"error":"nope"}"#.utf8)) }

        await #expect(throws: PlexError.self) {
            try await auth.requestPin()
        }
    }
}

/// Small lock box so mock handlers can record across concurrency domains.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }

    @discardableResult
    func modify<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}
