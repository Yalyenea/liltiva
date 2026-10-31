import Foundation
import Testing
@testable import KumoneCore

@MainActor private final class PageCacheGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Page cache integrity", .timeLimit(.minutes(1)))
@MainActor struct PageDataCacheTests {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/page-cache-tests/\(UUID())")
    }

    private func entered(_ gate: PageCacheGate) async throws {
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
    }

    @Test func diskRestoresEmptyValuesAndSeparatesAccounts() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root)
        try await cache.save([Int](), key: "library", scope: "a")
        try await cache.save([2], key: "library", scope: "b")
        let restarted = PageDataCache(directory: root)
        #expect(await restarted.load([Int].self, key: "library", scope: "a")?.value == [])
        #expect(await restarted.load([Int].self, key: "library", scope: "b")?.value == [2])
        let value = try await restarted.fetch([Int].self, key: "library", scope: "a", maxAge: 300) {
            Issue.record("An empty cached value is a successful result")
            return [3]
        }
        #expect(value.isEmpty)
    }

    @Test func navigationCancellationDoesNotRestartTheSharedRequest() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root), gate = PageCacheGate()
        defer { gate.open() }
        var calls = 0
        let first = Task {
            try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 60, session: "session-a") {
                calls += 1
                await gate.wait()
                return [1, 2]
            }
        }
        try await entered(gate)
        first.cancel()
        let second = Task {
            try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 60, session: "session-a") {
                calls += 1
                return [3]
            }
        }
        await Task.yield()
        gate.open()
        #expect(try await first.value == [1, 2])
        #expect(try await second.value == [1, 2])
        #expect(calls == 1)
        #expect(await cache.load([Int].self, key: "page", scope: "a")?.value == [1, 2])
    }

    @Test(arguments: [false, true])
    func mutationsInvalidateOlderReadersAndAllowANewRefresh(remove: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root), gate = PageCacheGate()
        defer { gate.open() }
        let old = Task {
            try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 60) {
                await gate.wait()
                return [1]
            }
        }
        try await entered(gate)
        if remove { try await cache.remove(key: "page", scope: "a") }
        else { try await cache.save([2], key: "page", scope: "a") }
        let fresh = try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 60, force: true) { [3] }
        #expect(fresh == [3])
        gate.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await cache.load([Int].self, key: "page", scope: "a")?.value == [3])
    }

    @Test func failedRefreshPreservesStaleDataAndNextAttemptCanRetry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        let cache = PageDataCache(directory: root, now: { now })
        try await cache.save([1], key: "page", scope: "a")
        now.addTimeInterval(301)
        await #expect(throws: URLError.self) {
            try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 300) {
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(await cache.load([Int].self, key: "page", scope: "a")?.value == [1])
        let fresh = try await cache.fetch([Int].self, key: "page", scope: "a", maxAge: 300) { [2] }
        #expect(fresh == [2])
    }

    @Test func renewedLoginDoesNotJoinThePreviousLogin() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root), gate = PageCacheGate()
        defer { gate.open() }
        var currentSession = "old"
        let old = Task {
            try await cache.fetch(Int.self, key: "page", scope: "a", maxAge: 60, session: "old") {
                await gate.wait()
                guard currentSession == "old" else { throw CancellationError() }
                return 1
            }
        }
        try await entered(gate)
        currentSession = "new"
        let fresh = try await cache.fetch(Int.self, key: "page", scope: "a", maxAge: 60, session: "new") { 2 }
        #expect(fresh == 2)
        gate.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await cache.load(Int.self, key: "page", scope: "a")?.value == 2)
    }

    @Test func diskCapacityIsBoundedAndNewestEntrySurvives() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root, maximumEntries: 2)
        for index in 0..<8 { try await cache.save([index], key: String(index), scope: "a") }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(files.count == 2)
        #expect(await cache.load([Int].self, key: "7", scope: "a")?.value == [7])
    }

    @Test func cachedContentShowsStaleDataBeforeNetworkAndRetainsItOnFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PageDataCache(directory: root), gate = PageCacheGate()
        defer { gate.open() }
        try await cache.save([1], key: "page", scope: "a")
        let model = CachedContent<[Int]>(cache: cache)
        let request = Task {
            await model.load(key: "page", scope: "a", session: "s", maxAge: 0, current: { true }) {
                await gate.wait()
                throw URLError(.notConnectedToInternet)
            }
        }
        try await entered(gate)
        #expect(model.value == [1] && !model.isLoading && model.isRefreshing)
        gate.open()
        await request.value
        #expect(model.value == [1] && model.error != nil && !model.isRefreshing)
    }

    @Test func dailyRolloverUsesTheServiceTimezone() {
        let justBefore = Date(timeIntervalSince1970: 1_800_000_000)
        let maxAge = NeteaseAPI.dailyCacheMaxAge(now: justBefore)
        let boundary = justBefore.addingTimeInterval(-maxAge)
        let old = CachedPage(value: [1], savedAt: boundary.addingTimeInterval(-1))
        let fresh = CachedPage(value: [2], savedAt: boundary.addingTimeInterval(1))
        #expect(!old.isFresh(maxAge: maxAge, now: justBefore))
        #expect(fresh.isFresh(maxAge: maxAge, now: justBefore))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        #expect(calendar.component(.hour, from: boundary) == 6)
        #expect(calendar.component(.minute, from: boundary) == 0)
    }

    @Test func rowMutationDoesNotExtendAnExpiredCollection() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let cache = PageDataCache(directory: root, now: { now })
        let savedAt = now.addingTimeInterval(-301)
        try await cache.save([1, 2], key: "page", scope: "a", savedAt: savedAt)
        let model = CachedContent<[Int]>(cache: cache)
        await model.load(key: "page", scope: "a", session: "s", maxAge: 300, current: { true }) {
            throw URLError(.notConnectedToInternet)
        }
        try await model.replace([2, 3])
        let saved = await cache.load([Int].self, key: "page", scope: "a")
        #expect(saved?.value == [2, 3] && saved?.savedAt == savedAt)
        #expect(saved?.isFresh(maxAge: 300, now: now) == false)
    }

    @Test func allWaitersReceiveTheSamePersistenceFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocks directory creation".utf8).write(to: root)
        let cache = PageDataCache(directory: root), gate = PageCacheGate()
        defer { gate.open() }
        var calls = 0
        let first = Task {
            try await cache.fetch(Int.self, key: "page", scope: "a", maxAge: 60) {
                calls += 1
                await gate.wait()
                return 1
            }
        }
        try await entered(gate)
        let second = Task {
            try await cache.fetch(Int.self, key: "page", scope: "a", maxAge: 60) {
                calls += 1
                return 2
            }
        }
        await Task.yield()
        gate.open()
        await #expect(throws: (any Error).self) { try await first.value }
        await #expect(throws: (any Error).self) { try await second.value }
        #expect(calls == 1)
    }

    @Test func libraryPaginationKeepsAllPagesAndRejectsTruncation() async throws {
        struct Item: Decodable, Identifiable { let id: Int }
        var offsets: [Int] = []
        let items: [Item] = try await NeteaseAPI.collectSublist(limit: 2) { _, offset in
            offsets.append(offset)
            return .init(data: offset == 0 ? [Item(id: 1), Item(id: 2)] : [Item(id: 3)], count: 3, hasMore: offset == 0)
        }
        #expect(items.map(\.id) == [1, 2, 3] && offsets == [0, 2])
        await #expect(throws: NeteaseAPIError.self) {
            let _: [Item] = try await NeteaseAPI.collectSublist(limit: 2) { _, _ in
                .init(data: [Item(id: 1)], count: 3, hasMore: false)
            }
        }
        await #expect(throws: NeteaseAPIError.self) {
            let _: [Item] = try await NeteaseAPI.collectSublist(limit: 2) { _, _ in
                .init(data: [Item(id: 1)], count: 3, hasMore: true)
            }
        }
    }
}
