import Foundation
import Testing
@testable import PlexKit

/// Exercises the real plex.tv API and a real server.
///
/// Disabled unless PLEX_LIVE is set and scripts/plex-dev-login.py has written
/// a token, so the normal suite stays hermetic and offline.
@Suite(
    "Live server",
    .enabled(if: ProcessInfo.processInfo.environment["PLEX_LIVE"] != nil)
)
struct LiveServerTests {
    struct DevCredentials: Decodable {
        let clientIdentifier: String
        let token: String
    }

    static func credentials() throws -> DevCredentials {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PlexKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".plex-dev.json")
        return try JSONDecoder().decode(DevCredentials.self, from: Data(contentsOf: url))
    }

    @Test("discovers and reaches a real server")
    func discoversRealServer() async throws {
        let credentials = try Self.credentials()
        let client = PlexClient(
            identity: PlexIdentity(clientIdentifier: credentials.clientIdentifier, product: "ctunes-dev")
        )
        let directory = PlexServerDirectory(client: client)

        let server = try await directory.selectServer(token: credentials.token)
        #expect(!server.machineIdentifier.isEmpty)
        #expect(server.baseURL.scheme == "https")
        print("→ reached \(server.name) at \(server.baseURL.absoluteString) (local: \(server.isLocal))")
    }
}
