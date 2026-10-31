import Foundation
import Testing
@testable import KumoneCore

private struct CachedSocialItem: Codable, Identifiable { let id: Int }
@MainActor private final class CachedSocialBinding {
    var session: String? = "login-a"
    var scope: String? = "netease:1"
}
private actor CachedSocialGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Social disk cache")
struct SocialCacheTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/social-cache-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func nestedEventsAndMusicSharesSurviveDiskEncoding() throws {
        let data = Data(#"{"id":2,"user":{"userId":1},"eventTime":1800000000000,"json":"{\"msg\":\"Forward\",\"song\":{\"id\":42,\"name\":\"Song\"},\"event\":{\"user\":{\"userId\":3},\"json\":\"{\\\"msg\\\":\\\"Original\\\",\\\"album\\\":{\\\"id\\\":7}}\"}}"}"#.utf8)
        let event = try JSONDecoder().decode(SocialEvent.self, from: data)
        let restored = try JSONDecoder().decode(SocialEvent.self, from: JSONEncoder().encode(event))
        #expect(restored.payload?.text == "Forward")
        #expect(restored.payload?.resource?.id == 42)
        #expect(restored.payload?.event?.user?.id == 3)
        #expect(restored.forwardedContent?.text == "Original")
        #expect(restored.forwardedContent?.resourceKind == .album)
        #expect(restored.forwardedContent?.resource?.id == 7)

        let message = try JSONDecoder().decode(PrivateMessage.self, from: Data(#"{"id":8,"fromUser":{"userId":2},"time":1234,"msg":"{\"msg\":\"hello\",\"playlist\":{\"id\":9,\"name\":\"Mix\"}}"}"#.utf8))
        let messageCopy = try JSONDecoder().decode(PrivateMessage.self, from: JSONEncoder().encode(message))
        #expect(messageCopy.content?.text == "hello")
        #expect(messageCopy.content?.resource?.name == "Mix")
        #expect(messageCopy.content?.resourceKind == .playlist)
        let notice = SocialNotification(id: "reply:1", user: message.fromUser, time: 1234,
                                        text: "Reply", context: "Original", resource: message.content?.resource,
                                        resourceKind: .playlist)
        let noticeCopy = try JSONDecoder().decode(SocialNotification.self, from: JSONEncoder().encode(notice))
        #expect(noticeCopy.context == "Original" && noticeCopy.resource?.id == 9 && noticeCopy.resourceKind == .playlist)
    }

    @Test @MainActor func cachedPaginationResumesAndFailedRefreshKeepsTheSnapshot() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory), binding = CachedSocialBinding()
        let first = SocialPageModel<CachedSocialItem>(cacheKey: "people", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { cursor in
            .init(items: [.init(id: cursor == nil ? 1 : 2)], nextCursor: cursor == nil ? 20 : 40)
        }
        await first.refresh(); await first.loadMore()
        var requested: [Int?] = []
        var fail = false
        let restored = SocialPageModel<CachedSocialItem>(cacheKey: "people", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { cursor in
            requested.append(cursor)
            if fail { throw URLError(.notConnectedToInternet) }
            return .init(items: [.init(id: 3)], nextCursor: nil)
        }
        await restored.refresh(force: false)
        #expect(requested.isEmpty && restored.items.map(\.id) == [1, 2] && restored.hasMore)
        fail = true
        await restored.refresh()
        #expect(restored.items.map(\.id) == [1, 2] && restored.hasMore && restored.error != nil)
        fail = false
        await restored.loadMore() // Retry the failed first-page refresh.
        #expect(requested.count == 2 && requested.allSatisfy { $0 == nil })
        #expect(restored.items.map(\.id) == [3] && !restored.hasMore)

        let resumed = SocialPageModel<CachedSocialItem>(cacheKey: "people", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { cursor in
            #expect(cursor == 40)
            return .init(items: [.init(id: 4)], nextCursor: nil)
        }
        try await cache.save(SocialPageSnapshot(items: [CachedSocialItem(id: 1), .init(id: 2)], nextCursor: 40, hasMore: true), key: "people", scope: "netease:1")
        await resumed.refresh(force: false); await resumed.loadMore()
        #expect(resumed.items.map(\.id) == [1, 2, 4] && !resumed.hasMore)
    }

    @Test @MainActor func emptyPagesAreCachedAndAHistoryStillMarksRead() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory), binding = CachedSocialBinding()
        try await cache.save(SocialPageSnapshot<CachedSocialItem>(items: [], nextCursor: nil, hasMore: false), key: "empty", scope: "netease:1")
        var requests = 0
        let cached = SocialPageModel<CachedSocialItem>(cacheKey: "empty", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { _ in
            requests += 1
            return .init(items: [], nextCursor: nil)
        }
        await cached.refresh(force: false)
        await cached.refresh(force: false)
        #expect(cached.hasLoaded && cached.items.isEmpty && requests == 0)
        let history = SocialPageModel<CachedSocialItem>(cacheKey: "empty", alwaysRefresh: true, cache: cache,
            scope: { binding.scope }, session: { binding.session }) { _ in
            requests += 1
            return .init(items: [], nextCursor: nil)
        }
        await history.refresh(force: false)
        #expect(history.hasLoaded && requests == 1)
        binding.session = "login-b"; binding.scope = "netease:2"
        await cached.refresh(force: false)
        #expect(requests == 2 && cached.items.isEmpty && cached.session == "login-b")
    }

    @Test @MainActor func reopeningJoinsARequestAfterTheFirstViewIsCancelled() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory), binding = CachedSocialBinding(), gate = CachedSocialGate()
        var requests = 0
        let first = SocialPageModel<CachedSocialItem>(cacheKey: "joined", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { _ in
            requests += 1
            await gate.wait()
            try Task.checkCancellation()
            return .init(items: [.init(id: 1)], nextCursor: nil)
        }
        let old = Task { await first.refresh(force: false) }
        for _ in 0..<100 { if await gate.entered { break }; await Task.yield() }
        old.cancel()
        let reopened = SocialPageModel<CachedSocialItem>(cacheKey: "joined", cache: cache,
            scope: { binding.scope }, session: { binding.session }) { _ in
            requests += 1
            return .init(items: [.init(id: 2)], nextCursor: nil)
        }
        // Force skips the disk TTL while still joining an active request.
        let joined = Task { await reopened.refresh() }
        for _ in 0..<100 { await Task.yield() }
        await gate.open(); await old.value; await joined.value
        #expect(requests == 1 && first.items.isEmpty && reopened.items.map(\.id) == [1])
        let saved = await cache.load(SocialPageSnapshot<CachedSocialItem>.self, key: "joined", scope: "netease:1")
        #expect(saved?.value.items.map(\.id) == [1])
    }
}
