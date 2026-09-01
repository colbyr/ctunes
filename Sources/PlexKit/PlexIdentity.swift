import Foundation

/// Identity headers Plex requires on every request, to plex.tv and to the
/// media server alike.
///
/// `clientIdentifier` must be stable across launches. Regenerating it makes
/// the server treat each launch as a brand new device, which litters the
/// account's authorized-device list and invalidates prior grants.
public struct PlexIdentity: Sendable {
    public let clientIdentifier: String
    public let product: String
    public let version: String
    public let device: String
    public let platform: String

    public init(
        clientIdentifier: String,
        product: String = "ctunes",
        version: String = "1.0",
        device: String = "iPhone",
        platform: String = "iOS"
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.device = device
        self.platform = platform
    }

    /// Loads the persisted client identifier, minting and storing one on first run.
    public static func persistent(
        store: KeychainStore = .standard,
        product: String = "ctunes"
    ) throws -> PlexIdentity {
        let key = "client-identifier"
        if let existing = try store.string(for: key) {
            return PlexIdentity(clientIdentifier: existing, product: product)
        }
        let minted = UUID().uuidString
        try store.set(minted, for: key)
        return PlexIdentity(clientIdentifier: minted, product: product)
    }

    var headers: [String: String] {
        [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Device": device,
            "X-Plex-Platform": platform,
            // Without this the server answers in XML and every decode fails.
            "Accept": "application/json",
        ]
    }
}
