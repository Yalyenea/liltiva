import Combine
import Foundation

struct TrackCommentsSnapshot: Codable {
    let comments: [TrackComment]
    let hotComments: [TrackComment]
    let total: Int
    let cursor: Int?
    let hasMore: Bool
}

@MainActor
final class TrackCommentsModel: ObservableObject {
    typealias Loader = (Int?) async throws -> TrackCommentsPage
    let trackID: Int
    @Published private(set) var comments: [TrackComment] = []
    @Published private(set) var hotComments: [TrackComment] = []
    @Published private(set) var total = 0
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var pendingLikes: Set<Int> = []
    @Published private(set) var pendingDeletes: Set<Int> = []
    @Published private(set) var error: String?
    @Published private(set) var mutationError: String?
    private(set) var session: String?
    private var cursor: Int?
    private var generation = 0
    private let client: NeteaseClient
    private let currentSession: @MainActor () -> String?
    private let loader: Loader
    private let cache: PageDataCache?
    private let currentScope: @MainActor () -> String?
    private var loadedScope: String?
    private var refreshFailed = false
    private var mutationRevision = 0
    private var cacheKey: String { "track-comments:\(trackID)" }

    init(trackID: Int, client: NeteaseClient = .shared, cache: PageDataCache? = nil,
         scope: @escaping @MainActor () -> String? = { AccountStore.shared.offlineScope },
         session: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession }, load: Loader? = nil) {
        self.trackID = trackID
        self.client = client
        self.cache = cache
        currentScope = scope
        currentSession = session
        loader = load ?? { try await NeteaseAPI.trackComments(trackID: trackID, before: $0, using: client) }
    }

    func refresh(force: Bool = true) async {
        // Keep an in-flight submission attached to its draft during a manual refresh.
        guard session != currentSession() || (!isSending && pendingLikes.isEmpty && pendingDeletes.isEmpty) else { return }
        let changed = session != currentSession() || loadedScope != currentScope()
        generation += 1
        session = currentSession()
        loadedScope = currentScope()
        if changed {
            comments = []; hotComments = []; total = 0
            cursor = nil; hasLoaded = false; hasMore = false
            isSending = false; pendingLikes = []; pendingDeletes = []
        }
        let ticket = generation, binding = currentSession(), revision = mutationRevision
        let scope = loadedScope
        isLoading = true; error = nil; mutationError = nil
        defer { if ticket == generation { isLoading = false } }
        if !hasLoaded || !force, let cache, let scope,
           let cached = await cache.load(TrackCommentsSnapshot.self, key: cacheKey, scope: scope) {
            guard isCurrent(ticket, binding), scope == currentScope(), revision == mutationRevision else { return }
            apply(cached.value)
            if !force, cached.isFresh(maxAge: 60) {
                refreshFailed = false
                return
            }
        }
        do {
            let value: TrackCommentsSnapshot
            if let cache, let scope {
                let sessionProvider = currentSession, scopeProvider = currentScope, loader = loader
                value = try await cache.fetch(TrackCommentsSnapshot.self, key: cacheKey, scope: scope,
                                              maxAge: 60, force: force, session: binding) {
                    guard binding == sessionProvider(), scope == scopeProvider() else { throw CancellationError() }
                    let page = try await loader(nil)
                    guard binding == sessionProvider(), scope == scopeProvider() else { throw CancellationError() }
                    return Self.firstSnapshot(page)
                }
            } else {
                value = Self.firstSnapshot(try await loader(nil))
            }
            guard isCurrent(ticket, binding), scope == currentScope(), revision == mutationRevision else { return }
            apply(value)
            refreshFailed = false
        } catch {
            guard isCurrent(ticket, binding), scope == currentScope() else { return }
            refreshFailed = true
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        if session != currentSession() || loadedScope != currentScope() || !hasLoaded || refreshFailed {
            await refresh(); return
        }
        guard !isLoading, hasMore else { return }
        let ticket = generation, binding = currentSession(), before = cursor, revision = mutationRevision
        isLoading = true
        error = nil
        defer { if ticket == generation { isLoading = false } }
        do {
            let page = try await loader(before)
            guard isCurrent(ticket, binding), revision == mutationRevision else { return }
            accept(page, before: before)
            await persist()
        } catch {
            guard isCurrent(ticket, binding) else { return }
            self.error = error.localizedDescription
        }
    }

    private func accept(_ page: TrackCommentsPage, before: Int?) {
        var seen = Set(comments.map(\.id))
        comments.append(contentsOf: page.comments.filter { seen.insert($0.id).inserted })
        if before == nil { hotComments = page.hotComments ?? [] }
        total = page.total
        let next = page.comments.last.map { Int($0.time) }
        // Preserve the server cursor even when local deletion removes the last row.
        hasMore = page.more && next.map { time in
            time > 0 && (before.map { time < $0 } ?? true)
        } == true
        cursor = next
        hasLoaded = true
    }

    private func apply(_ snapshot: TrackCommentsSnapshot) {
        comments = snapshot.comments; hotComments = snapshot.hotComments
        total = snapshot.total; cursor = snapshot.cursor
        hasMore = snapshot.hasMore; hasLoaded = true
    }

    private static func firstSnapshot(_ page: TrackCommentsPage) -> TrackCommentsSnapshot {
        var seen = Set<Int>()
        let next = page.comments.last.map { Int($0.time) }
        return .init(comments: page.comments.filter { seen.insert($0.id).inserted },
                     hotComments: page.hotComments ?? [], total: page.total, cursor: next,
                     hasMore: page.more && next.map { $0 > 0 } == true)
    }

    private func persist(mutation: Bool = false) async {
        guard let cache, let scope = loadedScope, scope == currentScope(), session == currentSession() else { return }
        let ticket = generation, binding = session
        let value = TrackCommentsSnapshot(comments: comments, hotComments: hotComments,
                                          total: total, cursor: cursor, hasMore: hasMore)
        do {
            if hasLoaded { try await cache.save(value, key: cacheKey, scope: scope) }
            // Posting before the initial response must not cache a partial thread.
            else { try await cache.remove(key: cacheKey, scope: scope) }
        } catch {
            var storageError = error
            if mutation {
                // If replacing the snapshot fails, remove its pre-mutation version.
                do { try await cache.remove(key: cacheKey, scope: scope) }
                catch { storageError = error }
            }
            guard isCurrent(ticket, binding) else { return }
            if mutation { mutationError = storageError.localizedDescription }
            else { self.error = storageError.localizedDescription }
        }
    }

    func send(_ content: String, replyTo: Int? = nil) async -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !text.isEmpty else { return false }
        guard let binding = currentSession() else { mutationError = NeteaseAPIError.needLogin.localizedDescription; return false }
        let ticket = generation
        isSending = true; mutationError = nil
        defer { if ticket == generation { isSending = false } }
        do {
            let comment = try await NeteaseAPI.sendTrackComment(trackID: trackID, content: text, replyTo: replyTo, using: client)
            guard isCurrent(ticket, binding) else { return false }
            mutationRevision += 1
            // A successful submission can await moderation and omit the comment object.
            if let comment, !comments.contains(where: { $0.id == comment.id }) {
                comments.insert(comment, at: 0)
                total += 1
            }
            if comment != nil {
                await persist(mutation: true)
            } else if let cache, let scope = loadedScope {
                // Moderated submissions have no row yet; force the next open to revalidate.
                do { try await cache.remove(key: cacheKey, scope: scope) }
                catch { if isCurrent(ticket, binding) { mutationError = error.localizedDescription } }
            }
            return true
        } catch {
            guard isCurrent(ticket, binding) else { return false }
            mutationError = error.localizedDescription
            return false
        }
    }

    func toggleLike(_ comment: TrackComment) async {
        guard let binding = currentSession(), !pendingLikes.contains(comment.id) else { return }
        let ticket = generation, liked = comment.liked != true
        pendingLikes.insert(comment.id); mutationError = nil
        defer { if ticket == generation { pendingLikes.remove(comment.id) } }
        do {
            try await NeteaseAPI.setTrackCommentLiked(trackID: trackID, commentID: comment.id, liked: liked, using: client)
            guard isCurrent(ticket, binding) else { return }
            func update(_ items: inout [TrackComment]) {
                guard let index = items.firstIndex(where: { $0.id == comment.id }) else { return }
                items[index].liked = liked
                items[index].likedCount = max(0, (items[index].likedCount ?? 0) + (liked ? 1 : -1))
            }
            mutationRevision += 1
            update(&comments); update(&hotComments)
            await persist(mutation: true)
        } catch {
            guard isCurrent(ticket, binding) else { return }
            mutationError = error.localizedDescription
        }
    }

    func delete(_ comment: TrackComment) async {
        guard let binding = currentSession(), !pendingDeletes.contains(comment.id) else { return }
        let ticket = generation
        pendingDeletes.insert(comment.id); mutationError = nil
        defer { if ticket == generation { pendingDeletes.remove(comment.id) } }
        do {
            try await NeteaseAPI.deleteTrackComment(trackID: trackID, commentID: comment.id, using: client)
            guard isCurrent(ticket, binding) else { return }
            mutationRevision += 1
            comments.removeAll { $0.id == comment.id }
            hotComments.removeAll { $0.id == comment.id }
            total = max(0, total - 1)
            await persist(mutation: true)
        } catch {
            guard isCurrent(ticket, binding) else { return }
            mutationError = error.localizedDescription
        }
    }

    private func isCurrent(_ ticket: Int, _ binding: String?) -> Bool {
        ticket == generation && binding == currentSession() && loadedScope == currentScope() && !Task.isCancelled
    }
}
