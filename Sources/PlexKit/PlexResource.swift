import Foundation

/// One device on the account. Music servers are those whose `provides`
/// includes "server".
public struct PlexResource: Decodable, Sendable {
    public let name: String
    public let clientIdentifier: String
    public let provides: String
    public let owned: Bool
    public let connections: [PlexConnection]

    public var isServer: Bool {
        provides.split(separator: ",").contains("server")
    }

    enum CodingKeys: String, CodingKey {
        case name, clientIdentifier, provides, owned
        case connections = "connections"
    }
}

public struct PlexConnection: Decodable, Sendable, Equatable {
    public let uri: String
    public let address: String
    public let port: Int
    public let local: Bool
    public let relay: Bool
    public let networkProtocol: String

    enum CodingKeys: String, CodingKey {
        case uri, address, port, local, relay
        case networkProtocol = "protocol"
    }

    /// Lower sorts first.
    ///
    /// A server advertises one connection per interface, so several "local"
    /// entries routinely point at virtual adapters that nothing can reach.
    /// Rank only decides probe order; reachability decides the winner.
    var rank: Int {
        if relay { return 2 }
        return local ? 0 : 1
    }
}
