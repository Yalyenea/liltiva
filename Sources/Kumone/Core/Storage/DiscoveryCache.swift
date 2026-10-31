import Foundation

/// Capture identity before a request: cookies may change while it is suspended.
@MainActor
struct DiscoveryCacheContext: Equatable {
    let scope: String
    let session: String?

    static var current: Self {
        let account = AccountStore.shared
        return Self(scope: account.offlineScope ?? "pending",
                    session: NeteaseClient.shared.authenticationFingerprint)
    }

    func validate() throws {
        try Task.checkCancellation()
        guard AccountStore.shared.offlineScope != nil, self == Self.current else { throw CancellationError() }
    }

    func fetch<Value: Codable & Sendable>(_ type: Value.Type, key: String, publicData: Bool = false,
                               maxAge: TimeInterval, force: Bool = false,
                               loader: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try validate()
        return try await PageDataCache.shared.fetch(type, key: key,
            scope: publicData ? "public" : scope, maxAge: maxAge, force: force, session: session) {
                try validate()
                let value = try await loader()
                // Never persist a response received under a superseded login.
                try validate()
                return value
            }
    }
}

@MainActor
enum DiscoveryCache {
    static let toplistsKey = "toplists"
    static let toplistsMaxAge: TimeInterval = 30 * 60

    static func toplists(context: DiscoveryCacheContext, force: Bool = false) async throws -> [ToplistItem] {
        try await context.fetch([ToplistItem].self, key: toplistsKey, publicData: true,
                                maxAge: toplistsMaxAge, force: force) {
            try await NeteaseAPI.toplists()
        }
    }
}
