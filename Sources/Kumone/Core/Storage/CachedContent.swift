import Combine
import Foundation

/// A page restores its last successful value before joining the shared refresh.
@MainActor
final class CachedContent<Value: Codable & Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var isLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private(set) var scope: String?
    private var session: String?
    private var key: String?
    private var generation = 0
    private let cache: PageDataCache

    init(cache: PageDataCache = .shared) { self.cache = cache }

    func load(key: String, scope: String?, session: String?, maxAge: TimeInterval, force: Bool = false,
              current: @escaping @MainActor () -> Bool,
              loader: @escaping @MainActor () async throws -> Value) async {
        generation += 1
        let ticket = generation
        if self.scope != scope || self.session != session || self.key != key {
            value = nil
            error = nil
        }
        self.scope = scope
        self.session = session
        self.key = key
        isLoading = value == nil
        isRefreshing = false
        defer { if ticket == generation { isLoading = false; isRefreshing = false } }
        guard let scope, current() else { return }
        if let saved = await cache.load(Value.self, key: key, scope: scope) {
            guard ticket == generation, current(), !Task.isCancelled else { return }
            value = saved.value
            isLoading = false
        }
        guard ticket == generation, current(), !Task.isCancelled else { return }
        isRefreshing = true
        error = nil
        do {
            let fetched = try await cache.fetch(Value.self, key: key, scope: scope, maxAge: maxAge,
                force: force, session: session) {
                    guard current() else { throw CancellationError() }
                    let value = try await loader()
                    guard current() else { throw CancellationError() }
                    return value
                }
            guard ticket == generation, current(), !Task.isCancelled else { return }
            value = fetched
        } catch {
            guard ticket == generation, current(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func replace(_ value: Value) async throws {
        guard let scope, let key else { return }
        generation += 1
        self.value = value
        isLoading = false
        isRefreshing = false
        // Changing one row does not revalidate the rest of an older collection.
        let savedAt = await cache.load(Value.self, key: key, scope: scope)?.savedAt
        try await cache.save(value, key: key, scope: scope, savedAt: savedAt)
    }
}
