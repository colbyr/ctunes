import Foundation

/// One music library: a section on a server. Rating keys are unique per
/// server, but what a person keeps about their music (the shortcuts, the
/// Quick Mix's picks, the favorites, a listener's vetoes) is about one
/// library's content, so state like that is filed under this.
public struct LibraryID: Codable, Sendable, Hashable {
    /// `PlexServer.machineIdentifier`.
    public let server: String
    /// `PlexSection.key`.
    public let section: String

    public init(server: String, section: String) {
        self.server = server
        self.section = section
    }

    /// For a `UserDefaults` or iCloud key: `shortcuts.<server>.<section>`.
    public func key(_ prefix: String) -> String {
        "\(prefix).\(server).\(section)"
    }
}
