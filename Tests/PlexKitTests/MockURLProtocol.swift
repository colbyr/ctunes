import Foundation

/// Routes URLSession traffic to a canned handler so the auth flow can be
/// exercised without network access.
///
/// Handlers are registered per-session rather than in one global slot: the
/// testing library runs tests in parallel, and shared handler state means
/// tests silently answer each other's requests.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data
    }

    private static let registry = Registry()
    private static let sessionHeader = "X-Mock-Session"

    private final class Registry: @unchecked Sendable {
        private var handlers: [String: @Sendable (URLRequest) -> Response] = [:]
        private let lock = NSLock()

        func store(_ handler: @escaping @Sendable (URLRequest) -> Response) -> String {
            let id = UUID().uuidString
            lock.withLock { handlers[id] = handler }
            return id
        }

        func handler(for id: String) -> (@Sendable (URLRequest) -> Response)? {
            lock.withLock { handlers[id] }
        }
    }

    /// A session whose traffic is answered only by `handler`.
    static func session(
        handler: @escaping @Sendable (URLRequest) -> Response
    ) -> URLSession {
        let id = registry.store(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [sessionHeader: id]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let id = request.value(forHTTPHeaderField: Self.sessionHeader),
            let handler = Self.registry.handler(for: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension MockURLProtocol.Response {
    static func json(_ body: String) -> Self {
        .init(body: Data(body.utf8))
    }
}
