import Combine
import Foundation

struct SocialPageSnapshot<Item> {
    let items: [Item]
    let nextCursor: Int?
    let hasMore: Bool
}
extension SocialPageSnapshot: Codable where Item: Codable {}
extension SocialPageSnapshot: Sendable where Item: Sendable {}

/// Keep pagination and its cursor together so restoring a page can continue
/// from exactly the last successfully displayed result.
@MainActor
final class SocialPageModel<Item: Identifiable>: ObservableObject {
    typealias Loader = (Int?) async throws -> SocialPage<Item>
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasMore = false
    private(set) var session: String?
    private var loadedScope: String?
    private var nextCursor: Int?
    private var generation = 0
    private var refreshFailed = false
    private let currentSession: @MainActor () -> String?
    private let loader: Loader
    private var cacheRead: ((String) async -> (SocialPageSnapshot<Item>, Date)?)?
    private var cacheWrite: ((SocialPageSnapshot<Item>, String) async throws -> Void)?
    private var cacheFetch: ((String, String, Bool) async throws -> SocialPageSnapshot<Item>)?
    private var currentScope: @MainActor () -> String? = { nil }
    private var maxAge: TimeInterval = 60
    private var alwaysRefresh = false

    init(session: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession }, load: @escaping Loader) {
        currentSession = session
        loader = load
    }

    convenience init(cacheKey: String, maxAge: TimeInterval = 60, alwaysRefresh: Bool = false,
                     cache: PageDataCache = .shared,
                     scope: @escaping @MainActor () -> String? = { AccountStore.shared.offlineScope },
                     session: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession },
                     load: @escaping Loader) where Item: Codable & Sendable {
        self.init(session: session, load: load)
        currentScope = scope
        self.maxAge = maxAge
        self.alwaysRefresh = alwaysRefresh
        cacheRead = { scope in
            guard let cached = await cache.load(SocialPageSnapshot<Item>.self, key: cacheKey, scope: scope) else { return nil }
            return (cached.value, cached.savedAt)
        }
        cacheWrite = { value, scope in
            try await cache.save(value, key: cacheKey, scope: scope)
        }
        cacheFetch = { requestedScope, binding, force in
            try await cache.fetch(SocialPageSnapshot<Item>.self, key: cacheKey, scope: requestedScope,
                                  maxAge: maxAge, force: force, session: binding) {
                guard binding == session(), requestedScope == scope() else { throw CancellationError() }
                let page = try await load(nil)
                guard binding == session(), requestedScope == scope() else { throw CancellationError() }
                return SocialPageModel<Item>.firstSnapshot(page)
            }
        }
    }

    func reset() {
        generation += 1
        session = currentSession()
        loadedScope = currentScope()
        items = []
        nextCursor = nil
        hasMore = false
        hasLoaded = false
        refreshFailed = false
        error = nil
        isLoading = false
    }

    func refresh(force: Bool = true) async {
        if session != currentSession() || loadedScope != currentScope() { reset() }
        guard let binding = currentSession() else { return }
        generation += 1
        let ticket = generation, scope = currentScope()
        isLoading = true
        error = nil
        defer { if ticket == generation { isLoading = false } }
        if !hasLoaded || !force, let scope, let cached = await cacheRead?(scope) {
            guard isCurrent(ticket, binding, scope) else { return }
            apply(cached.0)
            let age = Date().timeIntervalSince(cached.1)
            if !force, !alwaysRefresh, age >= 0, age < maxAge {
                refreshFailed = false
                return
            }
        }
        do {
            let value: SocialPageSnapshot<Item>
            if let scope, let cacheFetch {
                // The cache owns this request so another view can join it after navigation.
                value = try await cacheFetch(scope, binding, force || alwaysRefresh)
            } else {
                value = Self.firstSnapshot(try await loader(nil))
            }
            guard isCurrent(ticket, binding, scope) else { return }
            apply(value)
            refreshFailed = false
        } catch {
            guard isCurrent(ticket, binding, scope) else { return }
            refreshFailed = true
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        if session != currentSession() || loadedScope != currentScope() { reset() }
        if !hasLoaded || refreshFailed { await refresh(); return }
        guard let binding = currentSession(), !isLoading, hasMore else { return }
        let ticket = generation, cursor = nextCursor, scope = currentScope()
        isLoading = true
        error = nil
        defer { if ticket == generation { isLoading = false } }
        do {
            let page = try await loader(cursor)
            guard isCurrent(ticket, binding, scope) else { return }
            accept(page, after: cursor)
            if let scope { try await cacheWrite?(snapshot, scope) }
        } catch {
            guard isCurrent(ticket, binding, scope) else { return }
            self.error = error.localizedDescription
        }
    }

    private var snapshot: SocialPageSnapshot<Item> {
        .init(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }

    private static func firstSnapshot(_ page: SocialPage<Item>) -> SocialPageSnapshot<Item> {
        var seen = Set<Item.ID>()
        return .init(items: page.items.filter { seen.insert($0.id).inserted }, nextCursor: page.nextCursor,
                     hasMore: !page.items.isEmpty && page.nextCursor != nil)
    }

    private func apply(_ value: SocialPageSnapshot<Item>) {
        items = value.items
        nextCursor = value.nextCursor
        hasMore = value.hasMore
        hasLoaded = true
    }

    private func accept(_ page: SocialPage<Item>, after cursor: Int?) {
        var seen = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
        nextCursor = page.nextCursor
        hasMore = !page.items.isEmpty && page.nextCursor != nil && page.nextCursor != cursor
        hasLoaded = true
    }

    private func isCurrent(_ ticket: Int, _ binding: String, _ scope: String?) -> Bool {
        ticket == generation && binding == currentSession() && scope == currentScope() && !Task.isCancelled
    }
}

@MainActor
final class MessageCenterStore: ObservableObject {
    static let shared = MessageCenterStore()
    @Published private(set) var counts: MessageCounts?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private var session: String?
    private var generation = 0
    private let currentSession: @MainActor () -> String?
    private let loader: () async throws -> MessageCounts

    var unread: Int { session == currentSession() ? counts?.total ?? 0 : 0 }
    var currentCounts: MessageCounts? { session == currentSession() ? counts : nil }

    init(session: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession },
         load: @escaping () async throws -> MessageCounts = { try await NeteaseAPI.messageCounts() }) {
        currentSession = session
        loader = load
    }

    func reset() {
        generation += 1
        session = currentSession()
        counts = nil
        error = nil
        isLoading = false
    }

    func refresh(afterReading: Bool = false) async {
        if session != currentSession() { reset() }
        guard let binding = currentSession(), afterReading || !isLoading else { return }
        // A count request started before the read must not restore its old badge.
        if afterReading { generation += 1 }
        let ticket = generation
        isLoading = true
        defer { if ticket == generation { isLoading = false } }
        do {
            let counts = try await loader()
            guard ticket == generation, binding == currentSession(), !Task.isCancelled else { return }
            self.counts = counts
            error = nil
        } catch {
            guard ticket == generation, binding == currentSession(), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
