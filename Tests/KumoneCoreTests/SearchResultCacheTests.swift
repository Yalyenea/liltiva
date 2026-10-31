import Foundation
import Testing
@testable import KumoneCore

@Suite("Search result cache")
@MainActor
struct SearchResultCacheTests {
    private func key(query: String = "music", tab: String = "综合", scope: String = "guest", session: String? = nil) -> SearchResultCache.Key {
        .init(query: query, tab: tab, scope: scope, session: session)
    }

    @Test func expirationUsesSaveTimeRatherThanLastAccess() {
        let cache = SearchResultCache(maxAge: 60)
        let date = Date(timeIntervalSince1970: 1_000)
        cache.insert(.init(), for: key(), now: date)
        #expect(cache.value(for: key(), now: date.addingTimeInterval(59)) != nil)
        #expect(cache.value(for: key(), now: date.addingTimeInterval(60)) == nil)
    }

    @Test func evictsLeastRecentlyUsedResult() {
        let cache = SearchResultCache(capacity: 2)
        cache.insert(.init(), for: key(query: "first"))
        cache.insert(.init(), for: key(query: "second"))
        #expect(cache.value(for: key(query: "first")) != nil)
        cache.insert(.init(), for: key(query: "third"))
        #expect(cache.value(for: key(query: "second")) == nil)
        #expect(cache.value(for: key(query: "first")) != nil)
        #expect(cache.value(for: key(query: "third")) != nil)
    }

    @Test func clockRollbackInvalidatesTheResult() {
        let cache = SearchResultCache(maxAge: 60)
        let date = Date(timeIntervalSince1970: 1_000)
        cache.insert(.init(), for: key(), now: date)
        #expect(cache.value(for: key(), now: date.addingTimeInterval(-1)) == nil)
        #expect(cache.value(for: key(), now: date) == nil)
    }

    @Test func queryTabAccountAndLoginSessionAreIsolated() {
        let cache = SearchResultCache()
        let original = key(scope: "netease:1", session: "login-a")
        cache.insert(.init(), for: original)
        #expect(cache.value(for: original) != nil)
        #expect(cache.value(for: key(query: "other", scope: "netease:1", session: "login-a")) == nil)
        #expect(cache.value(for: key(tab: "单曲", scope: "netease:1", session: "login-a")) == nil)
        #expect(cache.value(for: key(scope: "netease:2", session: "login-a")) == nil)
        #expect(cache.value(for: key(scope: "netease:1", session: "login-b")) == nil)
        #expect(cache.value(for: key()) == nil)
    }
}
