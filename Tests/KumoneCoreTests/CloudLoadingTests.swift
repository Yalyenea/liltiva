import Foundation
import Testing
@testable import KumoneCore

@MainActor private final class CloudGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Cloud snapshots and refresh", .timeLimit(.minutes(1)))
@MainActor struct CloudLoadingTests {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/cloud-tests/\(UUID())")
    }

    private func response(_ ids: [Int], more: Bool? = false, name: String = "Song",
                          size: Any = "1024", maxSize: Any = 4096) throws -> NeteaseAPI.CloudResponse {
        var json: [String: Any] = ["data": ids.map { id in
            ["privateCloud": ["songId": id, "song": "\(name) \(id)", "artist": "Artist", "fileSize": 1024],
             "simpleSong": ["id": id, "name": "\(name) \(id)", "dt": 3000]]
        }, "size": size, "maxSize": maxSize]
        if let more { json["hasMore"] = more }
        return try JSONDecoder().decode(NeteaseAPI.CloudResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func waitForGate(_ gate: CloudGate) async throws {
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
    }

    @Test func paginatedCloudSurvivesRestartWithMetadataAndAccountIsolation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root)
        var offsets: [Int] = []
        let model = CloudContent(snapshots: store, accountScope: { "a" }, accountSession: { "session-a" },
            pageLoader: { limit, offset in
                #expect(limit == 1000)
                offsets.append(offset)
                switch offset {
                case 0: return try response(Array(1...1000), more: true)
                case 1000: return try response([1000, 1001], more: true)
                default: return try response([1002])
                }
            })
        await model.load()
        #expect(offsets == [0, 1000, 1002])
        #expect(model.tracks.map(\.id) == Array(1...1002))
        #expect(model.snapshot?.size == 1024 && model.snapshot?.maxSize == 4096)
        let restarted = CloudContent(snapshots: CloudSnapshotStore(directory: root),
            accountScope: { "a" }, accountSession: { "new-session-a" }, pageLoader: { _, _ in
                Issue.record("A fresh persisted cloud should not request the network")
                throw URLError(.notConnectedToInternet)
            })
        await restarted.load()
        #expect(restarted.tracks == model.tracks && !restarted.isLoading)
        #expect(restarted.snapshot?.items.first?.songName == "Song 1")
        #expect(restarted.snapshot?.items.first?.artist == "Artist")
        #expect(restarted.snapshot?.items.first?.fileSize == 1024)
        #expect(await store.load(scope: "b") == nil)
    }

    @Test func cachedCloudShowsBeforeRefreshAndReentrySharesWorkAfterCallerCancellation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root), gate = CloudGate()
        defer { gate.open() }
        let clock = Date()
        try await store.save(CloudSnapshot(items: try #require(response([1, 2]).data), size: 100, maxSize: 200,
                                           savedAt: clock.addingTimeInterval(-301)), scope: "a")
        var calls = 0
        let model = CloudContent(snapshots: store, accountScope: { "a" }, accountSession: { "session-a" },
            now: { clock }, pageLoader: { _, _ in
                calls += 1
                await gate.wait()
                return try response([2, 3], name: "Updated", size: 300, maxSize: "800")
            })
        let first = Task { await model.load() }
        try await waitForGate(gate)
        #expect(model.tracks.map(\.id) == [1, 2] && !model.isLoading && model.isRefreshing)
        first.cancel()
        let reentered = Task { await model.load() }
        await Task.yield()
        #expect(calls == 1 && model.tracks.map(\.id) == [1, 2])
        gate.open()
        await first.value
        await reentered.value
        #expect(model.tracks.map(\.id) == [2, 3])
        #expect(model.tracks.first?.name == "Updated 2")
        #expect(model.snapshot?.size == 300 && model.snapshot?.maxSize == 800)
        #expect(model.errorMessage == nil && !model.isRefreshing)
        await model.load()
        #expect(calls == 1)
        #expect(await store.load(scope: "a")?.items.map(\.id) == [2, 3])
    }

    @Test(arguments: [false, true])
    func laterPageFailureRetainsCompleteSnapshotIncludingEmptyCloud(empty: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root)
        let ids = empty ? [] : [1, 2]
        let saved = CloudSnapshot(items: try #require(response(ids).data), size: 20, maxSize: 200)
        try await store.save(saved, scope: "a")
        var calls = 0
        var failing = true
        let model = CloudContent(snapshots: store, accountScope: { "a" }, accountSession: { "session-a" },
            pageLoader: { _, offset in
                calls += 1
                if offset == 0 { return try response([3], more: true) }
                if failing { throw URLError(.notConnectedToInternet) }
                return try response([4])
            })
        await model.load()
        await model.load()
        #expect(calls == 0 && model.snapshot != nil && !model.isLoading)
        await model.load(force: true)
        #expect(calls == 2 && model.errorMessage != nil && !model.isLoading && !model.isRefreshing)
        #expect(model.tracks.map(\.id) == ids && model.snapshot?.size == 20)
        #expect(await store.load(scope: "a")?.items.map(\.id) == ids)
        failing = false
        await model.load(force: true)
        #expect(model.tracks.map(\.id) == [3, 4] && model.errorMessage == nil)
        #expect(await store.load(scope: "a")?.items.map(\.id) == [3, 4])
    }

    @Test(arguments: [false, true])
    func emptyRefreshClearsOldMembershipAndIsCached(omitHasMore: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root)
        try await store.save(CloudSnapshot(items: try #require(response([1]).data), size: 10, maxSize: 20), scope: "a")
        var calls = 0
        let model = CloudContent(snapshots: store, accountScope: { "a" }, accountSession: { "session-a" },
            pageLoader: { _, _ in calls += 1; return try response([], more: omitHasMore ? nil : false) })
        await model.load(force: true)
        await model.load()
        #expect(calls == 1 && model.snapshot?.items.isEmpty == true && model.errorMessage == nil)
        #expect(await store.load(scope: "a")?.items.isEmpty == true)
    }

    @Test(arguments: ["b", "signed-out", "same-account-new-session"])
    func accountChangesDiscardLateResponses(destination: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root), gate = CloudGate()
        defer { gate.open() }
        var scope: String? = "a", session: String? = "old-session"
        let model = CloudContent(snapshots: store, accountScope: { scope }, accountSession: { session },
            pageLoader: { _, _ in
                if session == "old-session" { await gate.wait(); return try response([1]) }
                return try response([2])
            })
        let first = Task { await model.load() }
        try await waitForGate(gate)
        scope = destination == "signed-out" ? nil : destination == "b" ? "b" : "a"
        session = scope == nil ? nil : "new-session"
        model.activateAccount(scope: scope, session: session)
        #expect(model.snapshot == nil)
        await model.load()
        gate.open()
        await first.value
        #expect(model.tracks.map(\.id) == (scope == nil ? [] : [2]))
        #expect(!model.isLoading && !model.isRefreshing)
        #expect(await store.load(scope: "a")?.items.map(\.id) == (scope == "a" ? [2] : nil))
        if scope == "b" { #expect(await store.load(scope: "b")?.items.map(\.id) == [2]) }
    }

    @Test(arguments: ["empty-more", "repeated-page", "missing-data", "bad-data"])
    func invalidPaginationCannotReplaceSavedCloud(kind: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSnapshotStore(directory: root)
        try await store.save(CloudSnapshot(items: try #require(response([1]).data)), scope: "a")
        var calls = 0
        let model = CloudContent(snapshots: store, accountScope: { "a" }, accountSession: { "session-a" },
            pageLoader: { _, _ in
                calls += 1
                switch kind {
                case "empty-more": return try response([], more: true)
                case "repeated-page": return try response([2], more: true)
                default:
                    let json = kind == "missing-data" ? "{\"hasMore\":false}" : "{\"data\":{},\"hasMore\":false}"
                    return try JSONDecoder().decode(NeteaseAPI.CloudResponse.self, from: Data(json.utf8))
                }
            })
        await model.load(force: true)
        #expect(calls == (kind == "repeated-page" ? 2 : 1))
        #expect(model.errorMessage != nil && model.tracks.map(\.id) == [1])
        #expect(await store.load(scope: "a")?.items.map(\.id) == [1])
    }

    @Test func freshnessHandlesExpiryAndClockChanges() {
        let now = Date()
        let snapshot = CloudSnapshot(items: [], savedAt: now)
        #expect(!snapshot.needsRefresh(now: now.addingTimeInterval(299)))
        #expect(snapshot.needsRefresh(now: now.addingTimeInterval(300)))
        #expect(snapshot.needsRefresh(now: now.addingTimeInterval(-1)))
    }
}
