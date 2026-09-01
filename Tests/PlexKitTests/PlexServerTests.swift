import Foundation
import Testing
@testable import PlexKit

@Suite("Server discovery")
struct PlexServerTests {
    let identity = PlexIdentity(clientIdentifier: "TEST-UUID")

    private func directory(
        handler: @escaping @Sendable (URLRequest) -> MockURLProtocol.Response
    ) -> PlexServerDirectory {
        PlexServerDirectory(
            client: PlexClient(identity: identity, session: MockURLProtocol.session(handler: handler))
        )
    }

    private static func identityBody(_ machine: String) -> MockURLProtocol.Response {
        .json(#"{"MediaContainer":{"machineIdentifier":"\#(machine)"}}"#)
    }

    @Test("decodes a real /resources payload")
    func decodesResources() async throws {
        let body = try Fixture.string("resources")
        let servers = try await directory { _ in .json(body) }.resources(token: "t")

        #expect(servers.count == 1)
        let server = try #require(servers.first)
        #expect(server.isServer)
        #expect(server.owned)
        #expect(server.connections.count == 6)
        // Four interfaces advertise themselves as local.
        #expect(server.connections.filter(\.local).count == 4)
        #expect(server.connections.filter(\.relay).count == 1)
    }

    @Test("ranks local ahead of remote, and relay last")
    func connectionRanking() throws {
        let local = PlexConnection(uri: "u", address: "a", port: 1, local: true, relay: false, networkProtocol: "https")
        let remote = PlexConnection(uri: "u", address: "a", port: 1, local: false, relay: false, networkProtocol: "https")
        let relay = PlexConnection(uri: "u", address: "a", port: 1, local: false, relay: true, networkProtocol: "https")

        #expect(local.rank < remote.rank)
        #expect(remote.rank < relay.rank)
    }

    /// The real payload advertises four local addresses on virtual interfaces
    /// that nothing can reach, so a reachable remote has to win.
    @Test("falls through unreachable local addresses to one that answers")
    func fallsThroughToReachable() async throws {
        let resources = try Fixture.string("resources")
        let directory = directory { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("plex.tv/api/v2/resources") { return .json(resources) }
            // Only the public address answers, exactly as on the real network.
            if url.contains("38-42-101-254") { return Self.identityBody("MACHINE-1") }
            return .init(status: 500, body: Data("unreachable".utf8))
        }

        let server = try await directory.selectServer(token: "t")
        #expect(server.machineIdentifier == "MACHINE-1")
        #expect(server.isLocal == false)
        #expect(server.baseURL.absoluteString.contains("38-42-101-254"))
    }

    @Test("prefers a local connection when one actually answers")
    func prefersReachableLocal() async throws {
        let resources = try Fixture.string("resources")
        let directory = directory { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("plex.tv/api/v2/resources") { return .json(resources) }
            // Both a local address and the public one answer.
            if url.contains("192-168-0-193") || url.contains("38-42-101-254") {
                return Self.identityBody("MACHINE-1")
            }
            return .init(status: 500, body: Data("unreachable".utf8))
        }

        let server = try await directory.selectServer(token: "t")
        #expect(server.isLocal)
        #expect(server.baseURL.absoluteString.contains("192-168-0-193"))
    }

    @Test("throws when nothing answers rather than returning a dead URL")
    func noneReachable() async throws {
        let resources = try Fixture.string("resources")
        let directory = directory { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("plex.tv/api/v2/resources") { return .json(resources) }
            return .init(status: 500, body: Data("down".utf8))
        }

        await #expect(throws: PlexError.self) {
            try await directory.selectServer(token: "t")
        }
    }
}
