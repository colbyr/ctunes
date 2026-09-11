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

    @Test("query items carry the same identity, without Accept")
    func queryItems() {
        let items = identity.queryItems
        let names = Set(items.map(\.name))
        for header in identity.headers.keys where header != "Accept" {
            #expect(names.contains(header), "\(header) missing from the query")
        }
        #expect(!names.contains("Accept"))
        #expect(items.first { $0.name == "X-Plex-Client-Identifier" }?.value == "TEST-UUID")
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

@Suite("API session")
struct PlexClientSessionTests {
    /// A LAN address the phone has walked away from hangs every request;
    /// the shared session's 60s kept the app stuck on it for a minute.
    @Test("fails fast rather than waiting a minute on a dead address")
    func shortRequestTimeout() {
        let config = PlexClient.apiSession.configuration
        #expect(config.timeoutIntervalForRequest <= 10)
        #expect(config.waitsForConnectivity == false)
    }
}
