import Foundation

/// Performs authenticated requests against plex.tv and against a media server.
///
/// Identity headers are injected here once so no call site ever hand-rolls them.
public actor PlexClient {
    public let identity: PlexIdentity
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(identity: PlexIdentity, session: URLSession = .shared) {
        self.identity = identity
        self.session = session
        self.decoder = JSONDecoder()
    }

    /// Builds a request carrying the identity headers, and the token when given.
    /// Nonisolated because it only reads the immutable identity, so callers
    /// that must stay synchronous (the player choosing an item URL) can use it.
    public nonisolated func request(
        _ method: String = "GET",
        url: URL,
        token: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in identity.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        return request
    }

    @discardableResult
    public func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.http(
                status: http.statusCode,
                body: String(data: data.prefix(512), encoding: .utf8)
            )
        }
        return data
    }

    public func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from request: URLRequest
    ) async throws -> T {
        let data = try await self.data(for: request)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PlexError.decoding(
                underlying: String(describing: error),
                body: String(data: data.prefix(512), encoding: .utf8)
            )
        }
    }

    public func get<T: Decodable & Sendable>(
        _ type: T.Type,
        url: URL,
        token: String? = nil
    ) async throws -> T {
        try await decode(type, from: request(url: url, token: token))
    }
}
