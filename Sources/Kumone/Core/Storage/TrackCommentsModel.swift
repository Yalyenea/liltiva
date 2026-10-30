import Combine
import Foundation

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

    init(trackID: Int, client: NeteaseClient = .shared,
         session: @escaping @MainActor () -> String? = { AccountStore.shared.socialSession }, load: Loader? = nil) {
        self.trackID = trackID
        self.client = client
        currentSession = session
        loader = load ?? { try await NeteaseAPI.trackComments(trackID: trackID, before: $0, using: client) }
    }

    func refresh() async {
        // Keep an in-flight submission attached to its draft during a manual refresh.
        guard session != currentSession() || !isSending else { return }
        generation += 1
        session = currentSession()
        comments = []; hotComments = []; total = 0
        cursor = nil; hasLoaded = false; hasMore = false
        isLoading = false; isSending = false
        pendingLikes = []; pendingDeletes = []
        error = nil; mutationError = nil
        await loadMore()
    }

    func loadMore() async {
        if session != currentSession() { await refresh(); return }
        guard !isLoading, !hasLoaded || hasMore else { return }
        let ticket = generation, binding = currentSession(), before = cursor
        isLoading = true
        error = nil
        defer { if ticket == generation { isLoading = false } }
        do {
            let page = try await loader(before)
            guard isCurrent(ticket, binding) else { return }
            var seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { seen.insert($0.id).inserted })
            if before == nil { hotComments = page.hotComments ?? [] }
            total = page.total
            let next = page.comments.last.map { Int($0.time) }
            // Time pagination avoids the service's large-offset limit and stops repeated pages.
            hasMore = page.more && next.map { time in
                time > 0 && (before.map { time < $0 } ?? true)
            } == true
            cursor = next
            hasLoaded = true
        } catch {
            guard isCurrent(ticket, binding) else { return }
            self.error = error.localizedDescription
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
            // A successful submission can await moderation and omit the comment object.
            if let comment, !comments.contains(where: { $0.id == comment.id }) {
                comments.insert(comment, at: 0)
                total += 1
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
            update(&comments); update(&hotComments)
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
            comments.removeAll { $0.id == comment.id }
            hotComments.removeAll { $0.id == comment.id }
            total = max(0, total - 1)
        } catch {
            guard isCurrent(ticket, binding) else { return }
            mutationError = error.localizedDescription
        }
    }

    private func isCurrent(_ ticket: Int, _ binding: String?) -> Bool {
        ticket == generation && binding == currentSession() && !Task.isCancelled
    }
}
