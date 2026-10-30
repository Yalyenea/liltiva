import Foundation

extension NeteaseAPI {
    static func trackComments(trackID: Int, before: Int? = nil,
                              using client: NeteaseClient = .shared) async throws -> TrackCommentsPage {
        let session = client.authenticationFingerprint
        let data = try await client.weapi("/v1/resource/comments/R_SO_4_\(trackID)",
            ["rid": trackID, "limit": 30, "offset": 0, "beforeTime": before ?? 0], absorbResponseCookies: false)
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        return try client.decoded(TrackCommentsPage.self, from: data)
    }

    static func sendTrackComment(trackID: Int, content: String, replyTo: Int? = nil,
                                 using client: NeteaseClient = .shared) async throws -> TrackComment? {
        struct Response: Decodable { let comment: TrackComment? }
        var payload: [String: Any] = ["threadId": "R_SO_4_\(trackID)", "content": content]
        if let replyTo { payload["commentId"] = replyTo }
        // The desktop client uses the v1 reply endpoint, and the ordinary add endpoint.
        let path = replyTo == nil ? "/resource/comments/add" : "/v1/resource/comments/reply"
        return try await commentMutation(Response.self, path: path, payload: payload, using: client).comment
    }

    static func setTrackCommentLiked(trackID: Int, commentID: Int, liked: Bool,
                                     using client: NeteaseClient = .shared) async throws {
        struct Response: Decodable { let code: Int }
        _ = try await commentMutation(Response.self, path: "/v1/comment/\(liked ? "like" : "unlike")",
            payload: ["threadId": "R_SO_4_\(trackID)", "commentId": commentID], using: client)
    }

    static func deleteTrackComment(trackID: Int, commentID: Int,
                                   using client: NeteaseClient = .shared) async throws {
        struct Response: Decodable { let code: Int }
        _ = try await commentMutation(Response.self, path: "/resource/comments/delete",
            payload: ["threadId": "R_SO_4_\(trackID)", "commentId": commentID], using: client)
    }

    private static func commentMutation<T: Decodable>(_ type: T.Type, path: String, payload: [String: Any],
                                                      using client: NeteaseClient) async throws -> T {
        guard let session = client.authenticationFingerprint else { throw NeteaseAPIError.needLogin }
        let data = try await client.weapi(path, payload, absorbResponseCookies: false)
        guard session == client.authenticationFingerprint else { throw CancellationError() }
        return try client.decoded(type, from: data)
    }
}
