import Foundation

struct TrackComment: Codable, Identifiable {
    let commentId: Int
    let user: UserProfile
    let content: String
    let expressionUrl: String?
    let time: Double
    var liked: Bool?
    var likedCount: Int?
    let beReplied: [Reply]?

    var id: Int { commentId }

    struct Reply: Codable {
        let user: UserProfile?
        let content: String?
    }
}

struct TrackCommentsPage: Codable {
    let comments: [TrackComment]
    // The first page includes popular comments; subsequent pages may omit them.
    let hotComments: [TrackComment]?
    let total: Int
    let more: Bool
}
