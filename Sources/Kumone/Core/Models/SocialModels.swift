import Foundation

extension UserProfile: Identifiable {
    var id: Int { userId }
}

struct SocialPage<Item> {
    let items: [Item]
    let nextCursor: Int?
}

extension SocialPage: Codable where Item: Codable {}

struct UserOverview: Codable {
    let profile: UserProfile
    let level: Int?
    let listenSongs: Int?
    let peopleCanSeeMyPlayRecord: Bool?
}

/// Messages and events carry their content as JSON inside a JSON string.
/// Decode only presentation data; preserve unsupported kinds as an explicit
/// placeholder instead of exposing protocol JSON in the interface.
struct SocialContent: Codable {
    let msg: String?
    let title: String?
    let content: String?
    let song: SocialResource?
    let playlist: SocialResource?
    let album: SocialResource?
    let event: ForwardedEvent?
    let user: UserProfile?

    struct ForwardedEvent: Codable {
        let user: UserProfile?
        let json: String?
    }

    static func parse(_ json: String?) throws -> Self? {
        guard let json, !json.isEmpty else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    var text: String { msg ?? content ?? title ?? String(localized: "暂不支持此消息类型") }
    var resource: SocialResource? { song ?? playlist ?? album }
    var resourceKind: SocialResource.Kind? {
        if song != nil { return .song }
        if playlist != nil { return .playlist }
        if album != nil { return .album }
        return nil
    }
}

struct SocialResource: Codable {
    enum Kind: String, Codable { case song, playlist, album }
    let id: Int
    let name: String?
    let picUrl: String?
    let coverImgUrl: String?
    let imgUrl: String?
    let resourceType: Int?

    var imageURL: URL? { (picUrl ?? coverImgUrl ?? imgUrl)?.resizedImageURL(160) }
}

struct SocialEvent: Codable, Identifiable {
    let id: Int
    let user: UserProfile
    let eventTime: Double
    let info: Info?
    let pics: [Picture]?
    let payload: SocialContent?
    let forwardedContent: SocialContent?

    struct Info: Codable {
        let commentCount: Int?
        let likedCount: Int?
    }
    struct Picture: Codable { let originUrl: String?; let squareUrl: String? }
    private enum CodingKeys: String, CodingKey { case id, user, eventTime, info, pics, json }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        user = try c.decode(UserProfile.self, forKey: .user)
        eventTime = try c.decode(Double.self, forKey: .eventTime)
        info = try c.decodeIfPresent(Info.self, forKey: .info)
        pics = try c.decodeIfPresent([Picture].self, forKey: .pics)
        payload = try SocialContent.parse(c.decodeIfPresent(String.self, forKey: .json))
        forwardedContent = try SocialContent.parse(payload?.event?.json)
    }

    // Store the same nested JSON shape accepted by the network decoder.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(user, forKey: .user)
        try c.encode(eventTime, forKey: .eventTime)
        try c.encodeIfPresent(info, forKey: .info)
        try c.encodeIfPresent(pics, forKey: .pics)
        if let payload {
            try c.encode(String(decoding: JSONEncoder().encode(payload), as: UTF8.self), forKey: .json)
        }
    }
}

struct PrivateConversation: Codable, Identifiable {
    var id: Int { user.userId }
    let user: UserProfile
    let content: SocialContent?
    let time: Double
    let unread: Int
}

struct PrivateConversationRecord: Codable {
    let fromUser: UserProfile
    let toUser: UserProfile
    let lastMsg: String?
    let lastMsgTime: Double
    let newMsgCount: Int?

    func conversation(ownerID: Int) throws -> PrivateConversation {
        .init(user: fromUser.userId == ownerID ? toUser : fromUser,
              content: try SocialContent.parse(lastMsg), time: lastMsgTime, unread: newMsgCount ?? 0)
    }
}

struct PrivateMessage: Codable, Identifiable {
    let id: Int
    let fromUser: UserProfile
    let time: Double
    let content: SocialContent?
    private enum CodingKeys: String, CodingKey { case id, fromUser, time, msg }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        fromUser = try c.decode(UserProfile.self, forKey: .fromUser)
        time = try c.decode(Double.self, forKey: .time)
        content = try SocialContent.parse(c.decodeIfPresent(String.self, forKey: .msg))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fromUser, forKey: .fromUser)
        try c.encode(time, forKey: .time)
        if let content {
            try c.encode(String(decoding: JSONEncoder().encode(content), as: UTF8.self), forKey: .msg)
        }
    }
}

struct SocialNotification: Codable, Identifiable {
    let id: String
    let user: UserProfile?
    let time: Double
    let text: String
    let context: String?
    let resource: SocialResource?
    let resourceKind: SocialResource.Kind?
}

struct CommentNotification: Codable {
    let commentId: Int
    let combindId: String?
    let user: UserProfile
    let time: Double
    let content: String
    let beRepliedContent: String?
    let resourceJson: String?

    func notification() throws -> SocialNotification {
        let resource = try resourceJson.map { try JSONDecoder().decode(SocialResource.self, from: Data($0.utf8)) }
        return .init(id: combindId ?? String(commentId), user: user, time: time, text: content,
                     context: beRepliedContent, resource: resource,
                     resourceKind: resource.flatMap { Self.kind(for: $0.resourceType) })
    }

    static func kind(for resourceType: Int?) -> SocialResource.Kind? {
        switch resourceType {
        case 4: return .song
        case 3: return .album
        case 0: return .playlist
        default: return nil
        }
    }
}

struct MentionNotification: Codable {
    let id: Int
    let user: UserProfile?
    let time: Double?
    let json: String?
    let event: SocialEvent?

    func notification() throws -> SocialNotification {
        let content = try SocialContent.parse(json) ?? event?.payload
        return .init(id: String(id), user: user ?? event?.user, time: time ?? event?.eventTime ?? 0,
                     text: content?.text ?? String(localized: "在动态中提到了你"), context: nil,
                     resource: content?.resource, resourceKind: content?.resourceKind)
    }
}

struct NoticeNotification: Codable {
    let id: Int
    let time: Double
    let notice: String

    private struct Content: Codable {
        let user: UserProfile?
        let content: String?
        let title: String?
        let type: Int?
        let track: SocialResource?
        let playlist: SocialResource?
        let comment: Comment?
        let generalNotice: GeneralNotice?

        struct Comment: Codable { let content: String? }
        struct GeneralNotice: Codable { let actionDesc: String?; let content: String? }

        var text: String {
            if let generalNotice {
                let parts = [generalNotice.actionDesc, generalNotice.content].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
            if let content, !content.isEmpty { return content }
            if let title, !title.isEmpty { return title }
            if comment != nil { return String(localized: "评论收到互动") }
            if playlist != nil { return String(localized: "歌单收到互动") }
            return String(localized: "收到一条通知")
        }
    }
    func notification() throws -> SocialNotification {
        let payload = try JSONDecoder().decode(Content.self, from: Data(notice.utf8))
        return .init(id: String(id), user: payload.user, time: time,
                     text: payload.text, context: payload.comment?.content,
                     resource: payload.track ?? payload.playlist,
                     resourceKind: payload.track != nil ? .song : payload.playlist != nil ? .playlist : nil)
    }
}

struct MessageCounts: Codable, Equatable {
    let msg: Int
    let comment: Int
    let forward: Int
    let notice: Int
    let follow: Int
    var total: Int { msg + comment + forward + notice + follow }
}
