import Foundation
import Testing
@testable import PlexKit

@Suite("Identity headers")
struct PlexIdentityTests {
    let identity = PlexIdentity(clientIdentifier: "TEST-UUID", product: "ctunes")

    @Test("carries every header Plex requires")
    func requiredHeaders() {
        let headers = identity.headers
        #expect(headers["X-Plex-Client-Identifier"] == "TEST-UUID")
        #expect(headers["X-Plex-Product"] == "ctunes")
        #expect(headers["X-Plex-Platform"] == "iOS")
        #expect(headers["X-Plex-Device"] == "iPhone")
        #expect(headers["X-Plex-Version"] != nil)
    }

    /// Omitting this makes the server answer in XML, which fails to decode
    /// with an error that points nowhere near the real cause.
    @Test("asks for JSON rather than XML")
    func acceptsJSON() {
        #expect(identity.headers["Accept"] == "application/json")
    }

    @Test("request injects identity headers and the token")
    func requestInjection() async {
        let client = PlexClient(identity: identity)
        let url = URL(string: "https://plex.tv/api/v2/resources")!
        let request = await client.request(url: url, token: "SECRET")

        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "SECRET")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "TEST-UUID")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("token header is absent when unauthenticated")
    func noTokenHeader() async {
        let client = PlexClient(identity: identity)
        let url = URL(string: "https://plex.tv/api/v2/pins")!
        let request = await client.request("POST", url: url)

        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(request.httpMethod == "POST")
    }
}
