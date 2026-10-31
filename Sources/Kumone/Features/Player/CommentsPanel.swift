import SwiftUI

struct CommentsPanel: View {
    let track: Track
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @Environment(\.openDestination) private var openDestination
    @StateObject private var model: TrackCommentsModel
    @State private var draft = ""
    @State private var replyingTo: TrackComment?
    @State private var deleting: TrackComment?
    @FocusState private var composerFocused: Bool

    init(track: Track) {
        self.track = track
        _model = StateObject(wrappedValue: TrackCommentsModel(trackID: track.id, cache: .shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.session == account.socialSession {
                        commentsSection("热门评论", items: model.hotComments)
                        commentsSection("最新评论", items: model.comments)
                        if model.hasLoaded && model.comments.isEmpty && model.hotComments.isEmpty {
                            EmptyStateView(icon: "bubble.left", title: "暂无评论", subtitle: "分享你的听歌感受吧")
                                .frame(minHeight: 180)
                        }
                        footer
                    }
                }
                .padding(.horizontal, 16)
            }
            Divider().opacity(0.3)
            composer
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .panelSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .noFocusRing()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track-comments-panel")
        .task(id: account.socialSession) { await model.refresh(force: false) }
        .onChange(of: account.socialSession) { _, _ in
            draft = ""; replyingTo = nil; deleting = nil
        }
        .alert("删除这条评论？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { comment in
            Button("删除评论", role: .destructive) { Task { await model.delete(comment) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("歌曲评论").font(.headline)
                    if model.hasLoaded {
                        Text(model.total.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(track.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            SocialRefreshButton(loading: model.isLoading || model.isSending || !model.pendingLikes.isEmpty || !model.pendingDeletes.isEmpty) {
                Task { await model.refresh() }
            }
            Button { player.activePanel = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("关闭评论")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder
    private func commentsSection(_ title: LocalizedStringKey, items: [TrackComment]) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 18).padding(.bottom, 4)
            ForEach(items) { comment in
                commentRow(comment)
                Divider().opacity(0.25)
            }
        }
    }

    private func commentRow(_ comment: TrackComment) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    player.activePanel = nil
                    openDestination(.profile(comment.user.userId))
                } label: {
                    HStack(spacing: 8) {
                        SocialAvatar(user: comment.user, size: 28)
                        Text(comment.user.nickname).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text(comment.content).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let expression = comment.expressionUrl, let url = URL(string: expression) {
                CachedAsyncImage(url: url)
                    .aspectRatio(contentMode: .fit).frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let replies = comment.beReplied, !replies.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(replies.enumerated()), id: \.offset) { _, reply in
                        Text([reply.user?.nickname, reply.content ?? String(localized: "评论已删除")]
                            .compactMap { $0 }.joined(separator: "："))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 14) {
                SocialTime(milliseconds: comment.time)
                Spacer(minLength: 0)
                Button {
                    if account.socialSession == nil { openLogin() }
                    else { replyingTo = comment; composerFocused = true }
                } label: { Text("回复") }
                .buttonStyle(.plain)
                .disabled(model.isSending)
                Button {
                    if account.socialSession == nil { openLogin() }
                    else { Task { await model.toggleLike(comment) } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: comment.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        if let count = comment.likedCount, count > 0 { Text(count.formatted()) }
                    }
                    .foregroundStyle(comment.liked == true ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.pendingLikes.contains(comment.id))
                .accessibilityLabel(comment.liked == true ? "取消点赞评论" : "点赞评论")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 13)
        .contextMenu {
            if comment.user.userId == account.authenticatedAccountID {
                Button("删除评论", role: .destructive) { deleting = comment }
                    .disabled(model.pendingDeletes.contains(comment.id))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.isLoading { ProgressView().controlSize(.small) }
            else if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await model.loadMore() } }
            } else if model.hasMore {
                Button("加载更多") { Task { await model.loadMore() } }
                    .accessibilityIdentifier("load-more-comments")
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = model.mutationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if account.socialSession != nil {
                if let replyingTo {
                    HStack {
                        Text("回复 \(replyingTo.user.nickname)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { self.replyingTo = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).disabled(model.isSending).accessibilityLabel("取消回复")
                    }
                }
                TextField("写下你的感受…", text: $draft, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .focused($composerFocused).disabled(model.isSending)
                    .accessibilityLabel("评论内容").accessibilityIdentifier("comment-composer")
                HStack {
                    Spacer()
                    if model.isSending { ProgressView().controlSize(.small) }
                    Button("发送") {
                        Task {
                            if await model.send(draft, replyTo: replyingTo?.id) {
                                draft = ""; replyingTo = nil
                                ToastCenter.shared.show(String(localized: "评论已提交"))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                    .disabled(model.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("send-comment")
                }
            } else {
                HStack {
                    Text("登录后发表评论").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("登录", action: openLogin).controlSize(.small)
                }
            }
        }
        .padding(14)
    }
}
