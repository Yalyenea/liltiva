import SwiftUI

struct MessagesView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @ObservedObject private var center = MessageCenterStore.shared
    @State private var category: MessageCategory = .privateMessages

    var body: some View {
        Group {
            if let uid = account.authenticatedAccountID {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("消息中心").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                            if let counts = center.currentCounts {
                                Text("未读消息 \(counts.msg + counts.comment + counts.forward + counts.notice)")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let counts = center.currentCounts, counts.follow > 0 {
                            Button("新增粉丝 \(counts.follow)") { openDestination(.people(uid, followers: true)) }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                        }
                        SocialRefreshButton { Task { await center.refresh() }; refreshID = UUID() }
                    }.padding(.top, 12).padding(.bottom, 22)
                    SocialTabBar(items: MessageCategory.allCases, selection: $category,
                                 title: { $0.title }, count: unreadCount)
                        .accessibilityLabel("消息分类")
                    if let error = center.error {
                        Text("未读数量暂不可用：\(error)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                    Group {
                        if category == .privateMessages { PrivateConversationsView(ownerID: uid) }
                        else { NotificationMessagesView(category: category, ownerID: uid) }
                    }
                    .padding(.top, 12)
                    .id("\(account.socialSession ?? "guest"):\(category.rawValue):\(refreshID)")
                }
                .frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                .padding(Theme.Layout.contentInset)
            } else { SocialLoginPrompt() }
        }
        .navigationTitle("消息中心")
        .task(id: account.socialSession) { await center.refresh() }
    }
    @State private var refreshID = UUID()

    private func unreadCount(_ category: MessageCategory) -> Int {
        guard let counts = center.currentCounts else { return 0 }
        switch category {
        case .privateMessages: return counts.msg
        case .comments: return counts.comment
        case .mentions: return counts.forward
        case .notices: return counts.notice
        }
    }
}

private enum MessageCategory: String, CaseIterable, Identifiable {
    case privateMessages, comments, mentions, notices
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .privateMessages: return "私信"
        case .comments: return "评论"
        case .mentions: return "@我"
        case .notices: return "通知"
        }
    }
}

private struct PrivateConversationsView: View {
    let ownerID: Int
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @StateObject private var model: SocialPageModel<PrivateConversation>

    init(ownerID: Int) {
        self.ownerID = ownerID
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "messages:conversations", alwaysRefresh: true) { try await NeteaseAPI.privateConversations(ownerID: ownerID, cursor: $0) })
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.session == account.socialSession {
                    ForEach(model.items) { conversation in
                        Button { openDestination(.conversation(conversation.user.userId, conversation.user.nickname)) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                SocialAvatar(user: conversation.user, size: 42)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(conversation.user.nickname).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        SocialTime(milliseconds: conversation.time)
                                    }
                                    HStack(alignment: .top) {
                                        Text(conversation.content?.text ?? String(localized: "分享了内容"))
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        Spacer(minLength: 8)
                                        if conversation.unread > 0 { UnreadCountBadge(count: conversation.unread) }
                                    }
                                }
                            }.padding(.horizontal, 12).padding(.vertical, 15).contentShape(Rectangle())
                        }.buttonStyle(.interactiveRow)
                        Divider().opacity(0.3).padding(.leading, 68)
                    }
                    if model.hasLoaded, model.items.isEmpty {
                        EmptyStateView(icon: "bubble.left.and.bubble.right", title: "暂无私信").frame(minHeight: 220)
                    }
                    SocialPageFooter(model: model)
                }
            }
        }.task(id: account.socialSession) { await model.refresh(force: false) }
    }
}

private struct NotificationMessagesView: View {
    let category: MessageCategory
    let ownerID: Int
    @StateObject private var model: SocialPageModel<SocialNotification>
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination

    init(category: MessageCategory, ownerID: Int) {
        self.category = category; self.ownerID = ownerID
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "messages:\(category.rawValue)", alwaysRefresh: true) { cursor in
            switch category {
            case .comments: return try await NeteaseAPI.commentMessages(uid: ownerID, cursor: cursor)
            case .mentions: return try await NeteaseAPI.mentionMessages(cursor: cursor)
            case .notices: return try await NeteaseAPI.noticeMessages(cursor: cursor)
            case .privateMessages: preconditionFailure("Private messages use their conversation list")
            }
        })
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if model.session == account.socialSession {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                if let user = item.user {
                                    Button { openDestination(.profile(user.userId)) } label: { SocialAvatar(user: user, size: 32) }
                                        .buttonStyle(.plain).accessibilityLabel(Text(user.nickname))
                                    Button(user.nickname) { openDestination(.profile(user.userId)) }
                                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                                } else {
                                    Image(systemName: "bell").foregroundStyle(.secondary)
                                    Text("网易云音乐").font(.system(size: 13, weight: .medium))
                                }
                                Spacer(minLength: 0)
                                SocialTime(milliseconds: item.time)
                            }
                            Text(item.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            if let context = item.context, !context.isEmpty {
                                Text(context).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                            }
                            if let resource = item.resource, let kind = item.resourceKind { SocialResourceLink(resource: resource, kind: kind) }
                        }.padding(.horizontal, 12).padding(.vertical, 12)
                        Divider().opacity(0.3).padding(.horizontal, 12)
                    }
                    if model.hasLoaded, model.items.isEmpty {
                        EmptyStateView(icon: "bell", title: "暂无消息").frame(minHeight: 220)
                    }
                    SocialPageFooter(model: model)
                }
            }
        }.task(id: account.socialSession) { await model.refresh(force: false) }
    }
}

struct ConversationView: View {
    let userID: Int
    let name: String
    @StateObject private var model: SocialPageModel<PrivateMessage>
    @EnvironmentObject private var account: AccountStore

    init(userID: Int, name: String) {
        self.userID = userID; self.name = name
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "messages:history:\(userID)", alwaysRefresh: true) { try await NeteaseAPI.privateHistory(uid: userID, cursor: $0) })
    }
    var body: some View {
        Group {
            if account.socialSession == nil { SocialLoginPrompt() }
            else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(name).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                        Spacer()
                        SocialRefreshButton(loading: model.isLoading) { Task { await refresh() } }
                    }.padding(.bottom, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if model.session == account.socialSession {
                                SocialPageFooter(model: model)
                                ForEach(model.items.sorted { $0.time < $1.time }) { message in
                                    let own = message.fromUser.userId == account.authenticatedAccountID
                                    HStack(alignment: .top, spacing: 10) {
                                        if own { Spacer(minLength: 40) }
                                        else { SocialAvatar(user: message.fromUser, size: 30) }
                                        VStack(alignment: .leading, spacing: 8) {
                                            SocialTime(milliseconds: message.time)
                                            let text = message.content?.text ?? String(localized: "分享了内容")
                                            if !text.isEmpty {
                                                Text(text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                                            } else if message.content?.resource == nil {
                                                Text("暂不支持此消息类型").font(.system(size: 12)).foregroundStyle(.secondary)
                                            }
                                            if let content = message.content, let resource = content.resource, let kind = content.resourceKind {
                                                SocialResourceLink(resource: resource, kind: kind)
                                            }
                                        }
                                        .padding(12)
                                        .background(own ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                        if !own { Spacer(minLength: 40) }
                                    }.id(message.id)
                                }
                                if model.hasLoaded, model.items.isEmpty {
                                    EmptyStateView(icon: "bubble.left", title: "暂无私信").frame(minHeight: 200)
                                }
                            }
                        }
                    }.defaultScrollAnchor(.bottom)
                }
                .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                .padding(Theme.Layout.contentInset)
            }
        }
        .task(id: account.socialSession) { await refresh() }
        .navigationTitle(name)
        .onDisappear { Task { await MessageCenterStore.shared.refresh() } }
    }

    private func refresh() async {
        await model.refresh()
        guard model.hasLoaded, model.session == account.socialSession, !Task.isCancelled else { return }
        // The history request marks this thread read; update the badges while
        // it is open, rather than waiting for navigation back to the list.
        await MessageCenterStore.shared.refresh(afterReading: true)
    }
}

struct UnreadCountBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.accent, in: Capsule())
            .accessibilityLabel(Text("\(count) 条未读"))
    }
}
