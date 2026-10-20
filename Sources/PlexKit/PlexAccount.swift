import Foundation

/// The plex.tv account a token belongs to, from `/api/v2/user`. Only the
/// `uuid` is kept: it is what per-account state is filed under, since two
/// accounts can open the same server and section.
struct PlexAccount: Decodable, Sendable {
    let uuid: String
}
