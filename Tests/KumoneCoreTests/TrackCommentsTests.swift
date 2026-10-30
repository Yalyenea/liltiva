import Foundation
import Testing
@testable import KumoneCore

private func commentFixture(_ id: Int, time: Double = 1000) throws -> TrackComment {
    try JSONDecoder().decode(TrackComment.self, from: Data("""
    {"commentId":\(id),"user":{"userId":7,"nickname":"Listener"},"content":"A comment",
     "time":\(time),"liked":false,"likedCount":2,"beReplied":[]}
    """.utf8))
}

private final class CommentsProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "MUSIC_U=untrusted-response-cookie; Path=/"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor private final class CommentSession { var value: String? = "account-a" }
private actor CommentResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Track comments", .serialized)
struct TrackCommentsTests {
    private func client(loggedIn: Bool = true) -> NeteaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentsProtocol.self]
        let client = NeteaseClient(configuration: configuration, persistsCookies: false)
        if loggedIn { client.setCookies(["MUSIC_U": "synthetic-comment-session"]) }
        return client
    }

    @Test func decodesRepliesAndMissingAnonymousLikeState() throws {
        let comment = try JSONDecoder().decode(TrackComment.self, from: Data(#"{"commentId":1,"user":{"userId":7},"content":"Reply","expressionUrl":"https://example.test/sticker.png","time":1000,"beReplied":[{"user":{"userId":8,"nickname":"Author"},"content":"Original"},{"content":null}]}"#.utf8))
        #expect(comment.id == 1 && comment.liked == nil)
        #expect(comment.expressionUrl == "https://example.test/sticker.png")
        #expect(comment.beReplied?.first?.content == "Original")
        #expect(comment.beReplied?.last?.content == nil)
        let page = try JSONDecoder().decode(TrackCommentsPage.self, from: Data(#"{"comments":[],"total":0,"more":false}"#.utf8))
        #expect(page.hotComments == nil && page.comments.isEmpty)
    }

    @Test func publicReadsUseTheSongThreadWithoutAbsorbingCookies() async throws {
        let client = client(loggedIn: false)
        defer { CommentsProtocol.handler = nil }
        CommentsProtocol.handler = { request in
            #expect(request.url?.path == "/weapi/v1/resource/comments/R_SO_4_42")
            return Data(#"{"code":200,"comments":[],"hotComments":[],"total":0,"more":false}"#.utf8)
        }
        let page = try await NeteaseAPI.trackComments(trackID: 42, before: 1000, using: client)
        #expect(page.total == 0 && client.authenticationFingerprint == nil)
    }

    @Test func postingReplyingLikingAndDeletingUseDistinctEndpoints() async throws {
        let client = client()
        let binding = client.authenticationFingerprint
        var paths: [String] = []
        defer { CommentsProtocol.handler = nil }
        CommentsProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            return Data(#"{"code":200,"comment":null}"#.utf8)
        }
        #expect(try await NeteaseAPI.sendTrackComment(trackID: 42, content: "Test", using: client) == nil)
        _ = try await NeteaseAPI.sendTrackComment(trackID: 42, content: "Reply", replyTo: 1, using: client)
        try await NeteaseAPI.setTrackCommentLiked(trackID: 42, commentID: 1, liked: true, using: client)
        try await NeteaseAPI.setTrackCommentLiked(trackID: 42, commentID: 1, liked: false, using: client)
        try await NeteaseAPI.deleteTrackComment(trackID: 42, commentID: 1, using: client)
        #expect(paths == ["/weapi/resource/comments/add", "/weapi/v1/resource/comments/reply",
                         "/weapi/v1/comment/like", "/weapi/v1/comment/unlike", "/weapi/resource/comments/delete"])
        #expect(client.authenticationFingerprint == binding)
    }

    @Test func writingRequiresLoginAndReadingRejectsAnAccountChange() async throws {
        let guest = client(loggedIn: false)
        await #expect(throws: NeteaseAPIError.self) {
            _ = try await NeteaseAPI.sendTrackComment(trackID: 42, content: "Test", using: guest)
        }
        let client = client()
        defer { CommentsProtocol.handler = nil }
        CommentsProtocol.handler = { _ in
            try client.clearAuthCookies()
            return Data(#"{"code":200,"comments":[],"total":0,"more":false}"#.utf8)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await NeteaseAPI.trackComments(trackID: 42, using: client)
        }
    }

    @Test @MainActor func timePaginationDeduplicatesAndStopsOnARepeatedCursor() async throws {
        let session = CommentSession()
        let hot = try commentFixture(1), newest = try commentFixture(2, time: 300),
            older = try commentFixture(3, time: 200), oldest = try commentFixture(4, time: 100)
        var cursors: [Int?] = []
        let model = TrackCommentsModel(trackID: 42, session: { session.value }) { before in
            cursors.append(before)
            if before == nil { return .init(comments: [newest, older], hotComments: [hot], total: 10, more: true) }
            if before == 200 { return .init(comments: [older, oldest], hotComments: nil, total: 10, more: true) }
            return .init(comments: [oldest], hotComments: nil, total: 10, more: true)
        }
        await model.refresh(); await model.loadMore(); await model.loadMore(); await model.loadMore()
        #expect(model.comments.map(\.id) == [2, 3, 4] && model.hotComments.map(\.id) == [1])
        #expect(cursors == [nil, 200, 100] && !model.hasMore)
    }

    @Test @MainActor func failedPaginationRetainsCommentsAndRetriesTheSameCursor() async throws {
        let session = CommentSession(), item = try commentFixture(1)
        var fail = true
        let model = TrackCommentsModel(trackID: 42, session: { session.value }) { before in
            if before != nil && fail { fail = false; throw URLError(.notConnectedToInternet) }
            return .init(comments: before == nil ? [item] : [], hotComments: nil, total: 1, more: before == nil)
        }
        await model.refresh(); await model.loadMore()
        #expect(model.error != nil && model.comments.count == 1 && model.hasMore)
        await model.loadMore()
        #expect(model.error == nil && !model.hasMore && model.comments.count == 1)
    }

    @Test @MainActor func lateRepliesCannotReplaceARefreshedAccount() async throws {
        let session = CommentSession(), gate = CommentResponseGate()
        let oldItem = try commentFixture(1), newItem = try commentFixture(2)
        var requests = 0
        let model = TrackCommentsModel(trackID: 42, session: { session.value }) { _ in
            requests += 1
            let old = requests == 1
            if old { await gate.wait() }
            return .init(comments: [old ? oldItem : newItem], hotComments: nil, total: 1, more: false)
        }
        let pending = Task { await model.refresh() }
        for _ in 0..<100 { if await gate.entered { break }; await Task.yield() }
        session.value = "account-b"
        await model.refresh()
        await gate.open(); await pending.value
        #expect(model.comments.map(\.id) == [2] && model.session == "account-b")
    }

    @Test @MainActor func failedSubmissionKeepsTheFeedAndSuccessUpdatesBothLikeCopies() async throws {
        let client = client(), item = try commentFixture(1)
        defer { CommentsProtocol.handler = nil }
        let model = TrackCommentsModel(trackID: 42, client: client, session: { client.authenticationFingerprint }) { _ in
            .init(comments: [item], hotComments: [item], total: 1, more: false)
        }
        await model.refresh()
        CommentsProtocol.handler = { _ in Data(#"{"code":403,"message":"Comment rejected"}"#.utf8) }
        #expect(await model.send("Draft") == false)
        #expect(model.mutationError != nil && model.comments.count == 1 && !model.isSending)
        CommentsProtocol.handler = { _ in Data(#"{"code":200}"#.utf8) }
        await model.toggleLike(item)
        #expect(model.comments.first?.liked == true && model.hotComments.first?.liked == true)
        #expect(model.comments.first?.likedCount == 3 && model.hotComments.first?.likedCount == 3)
        await model.delete(item)
        #expect(model.comments.isEmpty && model.hotComments.isEmpty && model.total == 0)
    }

    @Test @MainActor func moderatedSubmissionIsAcknowledgedWithoutInventingAComment() async throws {
        let client = client()
        defer { CommentsProtocol.handler = nil }
        CommentsProtocol.handler = { _ in Data(#"{"code":200,"comment":null}"#.utf8) }
        let model = TrackCommentsModel(trackID: 42, client: client, session: { client.authenticationFingerprint }) { _ in
            .init(comments: [], hotComments: nil, total: 0, more: false)
        }
        await model.refresh()
        #expect(await model.send("A submitted comment") == true)
        #expect(model.comments.isEmpty && model.total == 0 && model.mutationError == nil)
    }
}

@Suite("Live track comments")
struct TrackCommentsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LILTIVA_LIVE_COMMENTS"] == "1"))
    func publicSongCommentsAndTimePagination() async throws {
        let client = NeteaseClient(configuration: .ephemeral, persistsCookies: false)
        let first = try await NeteaseAPI.trackComments(trackID: 186016, using: client)
        #expect(first.total > 0 && !first.comments.isEmpty)
        let cursor = Int(try #require(first.comments.last).time)
        let second = try await NeteaseAPI.trackComments(trackID: 186016, before: cursor, using: client)
        #expect(!second.comments.isEmpty && second.comments.first?.id != first.comments.first?.id)
        #expect(second.comments.allSatisfy { $0.time <= Double(cursor) })
        #expect(client.authenticationFingerprint == nil)
    }
}
