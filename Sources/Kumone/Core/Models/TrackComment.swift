import Foundation

struct TrackComment: Decodable, Identifiable {
    let commentId: Int
    let user: UserProfile
    let content: String
    let expressionUrl: String?
    let time: Double
    var liked: Bool?
    var likedCount: Int?
    let beReplied: [Reply]?

    var id: Int { commentId }

    struct Reply: Decodable {
        let user: UserProfile?
        let content: String?
    }
}

struct TrackCommentsPage: Decodable {
    let comments: [TrackComment]
    // The first page includes popular comments; subsequent pages may omit them.
    let hotComments: [TrackComment]?
    let total: Int
    let more: Bool
}
