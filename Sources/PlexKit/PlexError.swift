import Foundation

public enum PlexError: Error, Sendable {
    case keychain(OSStatus)
    case http(status: Int, body: String?)
    case decoding(underlying: String, body: String?)
    case noServerReachable
    case authorizationTimedOut
    case notAuthenticated
    /// The library is a snapshot; the server has to answer for this.
    case offline
}

extension PlexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain error \(status)."
        case .http(let status, let body):
            return "Server returned HTTP \(status).\(body.map { " \($0)" } ?? "")"
        case .decoding(let underlying, _):
            return "Could not decode the server response: \(underlying)"
        case .noServerReachable:
            return "No Plex server could be reached. Check Settings › Privacy › Local Network."
        case .authorizationTimedOut:
            return "Timed out waiting for sign-in to be approved."
        case .notAuthenticated:
            return "Not signed in to Plex."
        case .offline:
            return "Not available offline."
        }
    }
}
