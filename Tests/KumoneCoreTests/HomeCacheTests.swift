import Foundation
import Testing
@testable import KumoneCore

@MainActor
private final class HomeResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Home cache")
@MainActor
struct HomeCacheTests {
    private func directory() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/home-cache-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var emptyLoaders: HomeViewModel.Loaders {
        .init(recommendations: { _ in [] }, toplists: { [] }, albums: { [] },
              artists: { [] }, radar: { [] }, daily: { _ in [] })
    }

    @Test func successfulEmptySectionsRespectTTLAndCanBeRefreshed() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory)
        let binding = DiscoveryCacheContext(scope: "guest", session: nil)
        var requests = 0
        var loaders = emptyLoaders
        loaders.recommendations = { _ in requests += 1; return [] }
        let model = HomeViewModel(cache: cache, currentContext: { binding }, loaders: loaders)
        await model.load(loggedIn: false)
        await model.load(loggedIn: false)
        #expect(requests == 1)
        #expect(model.isEmpty && model.refreshError == nil)
        guard case .loaded = model.state else {
            Issue.record("An empty successful homepage must remain a loaded page")
            return
        }
        await model.reload(loggedIn: false)
        #expect(requests == 2)
    }

    @Test func previousAppearanceCannotFinishTheCurrentRefresh() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory)
        let binding = DiscoveryCacheContext(scope: "guest", session: nil)
        let firstArtists = HomeResponseGate(), secondRecommendations = HomeResponseGate()
        try await cache.save([PlaylistSummary](), key: "home.recommendations", scope: "guest")
        var loaders = emptyLoaders
        loaders.artists = { await firstArtists.wait(); return [] }
        loaders.recommendations = { _ in
            await secondRecommendations.wait()
            return []
        }
        let model = HomeViewModel(cache: cache, currentContext: { binding }, loaders: loaders)
        let first = Task { await model.load(loggedIn: false) }
        await firstArtists.waitUntilEntered()
        // The first visit uses the seeded recommendations snapshot. A forced
        // second visit starts a new request while the first artists reply waits.
        let second = Task { await model.load(loggedIn: false, force: true) }
        await secondRecommendations.waitUntilEntered()
        firstArtists.open()
        await first.value
        #expect(model.isRefreshing)
        secondRecommendations.open()
        await second.value
        #expect(!model.isRefreshing && model.refreshError == nil)
    }

    @Test func switchingAccountRejectsLatePersonalizedDataBeforeSaving() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory)
        var binding = DiscoveryCacheContext(scope: "netease:1", session: "login-a")
        let oldResponse = HomeResponseGate()
        let oldPlaylist = try JSONDecoder().decode(PlaylistSummary.self, from: Data(#"{"id":1,"name":"Old account"}"#.utf8))
        let newPlaylist = try JSONDecoder().decode(PlaylistSummary.self, from: Data(#"{"id":2,"name":"New account"}"#.utf8))
        var requests = 0
        var loaders = emptyLoaders
        loaders.recommendations = { _ in
            requests += 1
            if requests == 1 { await oldResponse.wait(); return [oldPlaylist] }
            return [newPlaylist]
        }
        let model = HomeViewModel(cache: cache, currentContext: { binding }, loaders: loaders)
        let first = Task { await model.load(loggedIn: false) }
        await oldResponse.waitUntilEntered()
        binding = .init(scope: "netease:2", session: "login-b")
        #expect(!model.matchesCurrentAccount)
        await model.load(loggedIn: false)
        oldResponse.open()
        await first.value
        #expect(model.recommendPlaylists.map(\.id) == [2])
        let oldSnapshot = await cache.load([PlaylistSummary].self, key: "home.recommendations", scope: "netease:1")
        #expect(oldSnapshot == nil)
    }
}
