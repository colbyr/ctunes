import Foundation

/// Where the client identifier and auth token live.
///
/// Abstracted so tests and SwiftUI previews can run without touching the real
/// keychain, which needs entitlements a test binary doesn't have.
public protocol SecretStore: Sendable {
    func string(for key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func remove(for key: String) throws
}

extension KeychainStore: SecretStore {}

/// Non-persistent store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func string(for key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String, for key: String) throws {
        lock.withLock { values[key] = value }
    }

    public func remove(for key: String) throws {
        lock.withLock { values[key] = nil }
    }
}
