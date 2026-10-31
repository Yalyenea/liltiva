import Combine
import Foundation

@MainActor
final class CloudContent: ObservableObject {
    static let shared = CloudContent()

    @Published private(set) var snapshot: CloudSnapshot?
    @Published private(set) var isLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private(set) var loadedScope: String?
    private var loadedSession: String?
    private var requestID = UUID()
    private var refreshTask: Task<Void, Never>?
    private let snapshots: CloudSnapshotStore
    private let accountScope: @MainActor () -> String?
    private let accountSession: @MainActor () -> String?
    private let pageLoader: (Int, Int) async throws -> NeteaseAPI.CloudResponse
    private let now: () -> Date

    init(snapshots: CloudSnapshotStore = .shared,
         accountScope: @escaping @MainActor () -> String? = {
             AccountStore.shared.authenticatedAccountID.map { "netease:\($0)" }
         },
         accountSession: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession },
         now: @escaping () -> Date = { .now },
         pageLoader: @escaping (Int, Int) async throws -> NeteaseAPI.CloudResponse = {
             try await NeteaseAPI.cloudSongs(limit: $0, offset: $1)
         }) {
        self.snapshots = snapshots
        self.accountScope = accountScope
        self.accountSession = accountSession
        self.now = now
        self.pageLoader = pageLoader
    }

    var tracks: [Track] { snapshot?.items.compactMap(\.simpleSong) ?? [] }

    func activateAccount(scope: String?, session: String?) {
        guard loadedScope != scope || loadedSession != session else { return }
        requestID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        loadedScope = scope
        loadedSession = session
        snapshot = nil
        errorMessage = nil
        isLoading = scope != nil
        isRefreshing = false
    }

    func load(force: Bool = false) async {
        let scope = accountScope(), session = accountSession()
        activateAccount(scope: scope, session: session)
        guard let scope, session != nil else {
            isLoading = false
            errorMessage = String(localized: "登录后才能查看音乐云盘")
            return
        }
        if let refreshTask { await refreshTask.value; return }
        let ticket = UUID()
        requestID = ticket
        // Navigation only awaits this task. Leaving the page must not cancel
        // the shared refresh or make a quick return start the same work again.
        let task = Task {
            defer {
                if requestID == ticket {
                    isLoading = false
                    isRefreshing = false
                    refreshTask = nil
                }
            }
            if snapshot == nil {
                let saved = await snapshots.load(scope: scope)
                guard valid(ticket, scope: scope, session: session) else { return }
                snapshot = saved
                isLoading = saved == nil
            }
            guard valid(ticket, scope: scope, session: session) else { return }
            if !force, let snapshot, !snapshot.needsRefresh(now: now()), errorMessage == nil { return }
            isRefreshing = true
            errorMessage = nil
            do {
                let fetched = try await fetchPages(ticket: ticket, scope: scope, session: session)
                guard valid(ticket, scope: scope, session: session) else { return }
                // Publish and persist only complete lists. A failed later page
                // must leave the previous snapshot (including an empty one) intact.
                try await snapshots.save(fetched, scope: scope)
                guard valid(ticket, scope: scope, session: session) else { return }
                snapshot = fetched
            } catch {
                guard valid(ticket, scope: scope, session: session) else { return }
                errorMessage = error.localizedDescription
            }
        }
        refreshTask = task
        await task.value
    }

    private func fetchPages(ticket: UUID, scope: String, session: String?) async throws -> CloudSnapshot {
        let limit = 1000
        var items: [CloudSongItem] = []
        var seen: Set<Int> = []
        var offset = 0
        var size: Int64?, maxSize: Int64?
        while true {
            guard valid(ticket, scope: scope, session: session) else { throw CancellationError() }
            let response = try await pageLoader(limit, offset)
            guard valid(ticket, scope: scope, session: session) else { throw CancellationError() }
            guard let page = response.data, page.allSatisfy({ $0.id > 0 }) else { throw CloudLoadingError.incomplete }
            if offset == 0 { size = response.size; maxSize = response.maxSize }
            let added = page.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: added)
            let hasMore = response.hasMore ?? (page.count == limit)
            // A server repeating a page or claiming more after an empty page
            // cannot make progress. Never persist that truncated membership.
            if !page.isEmpty, added.isEmpty { throw CloudLoadingError.incomplete }
            if !hasMore { break }
            guard !page.isEmpty else { throw CloudLoadingError.incomplete }
            offset += page.count
        }
        return CloudSnapshot(items: items, size: size, maxSize: maxSize, savedAt: now())
    }

    private func valid(_ ticket: UUID, scope: String, session: String?) -> Bool {
        requestID == ticket && !Task.isCancelled && accountScope() == scope && accountSession() == session
    }
}

private enum CloudLoadingError: LocalizedError {
    case incomplete
    var errorDescription: String? { String(localized: "云盘数据不完整，请重试") }
}
