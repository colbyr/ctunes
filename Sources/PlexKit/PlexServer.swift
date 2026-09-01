import Foundation

/// A server connection that answered a probe.
public struct PlexServer: Sendable, Equatable {
    public let name: String
    public let machineIdentifier: String
    public let baseURL: URL
    public let isLocal: Bool
}

private struct IdentityResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        let machineIdentifier: String
    }
    let mediaContainer: Container

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

/// Finds a reachable server for the signed-in account.
public actor PlexServerDirectory {
    private let client: PlexClient

    public init(client: PlexClient) {
        self.client = client
    }

    public func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await client.get([PlexResource].self, url: url, token: token)
    }

    /// Probes every connection at once and keeps the best-ranked one that
    /// answers.
    ///
    /// Probing concurrently rather than in rank order matters: unreachable
    /// local addresses fail by timing out, so walking the list in order would
    /// stall for the full timeout on each one before trying the connection
    /// that actually works.
    public func selectServer(
        token: String,
        timeout: Duration = .seconds(5)
    ) async throws -> PlexServer {
        let servers = try await resources(token: token).filter(\.isServer)

        for resource in servers {
            let ranked = resource.connections.enumerated().sorted {
                ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset)
            }

            let reachable = await withTaskGroup(
                of: (Int, PlexServer)?.self,
                returning: [(Int, PlexServer)].self
            ) { group in
                for (order, (_, connection)) in ranked.enumerated() {
                    group.addTask {
                        guard let server = await self.probe(
                            connection,
                            resourceName: resource.name,
                            token: token,
                            timeout: timeout
                        ) else { return nil }
                        return (order, server)
                    }
                }
                var found: [(Int, PlexServer)] = []
                for await result in group {
                    if let result { found.append(result) }
                }
                return found
            }

            if let best = reachable.min(by: { $0.0 < $1.0 })?.1 {
                return best
            }
        }
        throw PlexError.noServerReachable
    }

    func probe(
        _ connection: PlexConnection,
        resourceName: String,
        token: String,
        timeout: Duration
    ) async -> PlexServer? {
        guard let url = URL(string: connection.uri + "/identity") else { return nil }
        do {
            var request = await client.request(url: url, token: token)
            request.timeoutInterval = Double(timeout.components.seconds)
            let identity = try await client.decode(IdentityResponse.self, from: request)
            guard let base = URL(string: connection.uri) else { return nil }
            return PlexServer(
                name: resourceName,
                machineIdentifier: identity.mediaContainer.machineIdentifier,
                baseURL: base,
                isLocal: connection.local
            )
        } catch {
            return nil
        }
    }
}
