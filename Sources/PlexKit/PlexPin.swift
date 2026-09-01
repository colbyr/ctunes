import Foundation

/// A PIN link request. `authToken` stays nil until the user approves the
/// device in a browser, which is what polling waits for.
public struct PlexPin: Decodable, Sendable, Equatable {
    public let id: Int
    public let code: String
    public let authToken: String?

    public var isAuthorized: Bool { authToken?.isEmpty == false }
}
