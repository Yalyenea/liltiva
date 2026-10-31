import SwiftUI

struct ProfileView: View {
    let userID: Int
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @State private var overview: UserOverview?
    @State private var overviewSession: String?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var tab: ProfileTab = .playlists
    @ObservedObject private var messages = MessageCenterStore.shared

    private enum ProfileTab: String, CaseIterable, Identifiable {
        case playlists, events, feed, ranking
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .playlists: return "歌单"
            case .events: return "动态"
            case .feed: return "关注动态"
            case .ranking: return "听歌排行"
            }
        }
    }
    private var isSelf: Bool { account.authenticatedAccountID == userID }

    var body: some View {
        let selectedTab = tab
        Group {
            if account.socialSession == nil { SocialLoginPrompt() }
            else if let overview, overviewSession == account.socialSession {
                GeometryReader { geometry in
                  let width = min(1120, max(0, geometry.size.width - 2 * Theme.Layout.contentInset))
                  ScrollView {
                    // Only the selected content needs lazy rows. Keeping the
                    // small page shell eager lets tab changes replace it directly.
                    VStack(alignment: .leading, spacing: 0) {
                        header(overview).padding(.top, 12).padding(.bottom, 22)
                        if let error {
                            Text(error).font(.callout).foregroundStyle(.secondary).padding(.bottom, 12)
                        }
                        SocialTabBar(items: ProfileTab.allCases.filter { isSelf || $0 != .feed },
                                     selection: $tab, title: { $0.title })
                            .accessibilityLabel("个人主页内容")
                        content(overview, width: width, tab: selectedTab)
                            .padding(.top, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PlayerClearanceSpacer()
                    }
                    .frame(width: width, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.bottom, Theme.Layout.contentInset)
                  }
                }
            } else if let error {
                ErrorStateView(message: error) { Task { await load() } }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle("个人主页")
        .task(id: account.socialSession) { await load(force: false) }
    }

    private func header(_ overview: UserOverview) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            AdaptiveStack(horizontalMinimum: 620, spacing: 18) {
                HStack(alignment: .center, spacing: 20) {
                    SocialAvatar(user: overview.profile, size: 80)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 9) {
                        Text(overview.profile.nickname)
                            .font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                            .lineLimit(2).textSelection(.enabled)
                        HStack(spacing: 8) {
                            if let level = overview.level {
                                Text("等级 \(level)")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                            }
                            if isSelf, account.membershipTier != .free {
                                Text(account.membershipTier.displayName)
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            } else if overview.profile.vipType > 0 { VIPBadge() }
                        }.font(.system(size: 10, weight: .medium))
                        if let signature = overview.profile.signature, !signature.isEmpty {
                            Text(signature).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if isSelf {
                        Button { openDestination(.messages) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "tray")
                                Text("消息中心")
                                if messages.unread > 0 { UnreadCountBadge(count: messages.unread) }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.interactiveRow)
                    }
                    SocialRefreshButton(loading: loading) { Task { await load() } }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { socialCounts(overview); listeningCount(overview) }
                VStack(alignment: .leading, spacing: 12) { socialCounts(overview); listeningCount(overview) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func socialCounts(_ overview: UserOverview) -> some View {
        HStack(spacing: 22) {
            stat("关注的人", count: overview.profile.follows) { openDestination(.people(userID, followers: false)) }
            stat("粉丝", count: overview.profile.followeds) { openDestination(.people(userID, followers: true)) }
            stat("动态", count: overview.profile.eventCount) { tab = .events }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func listeningCount(_ overview: UserOverview) -> some View {
        if let listened = overview.listenSongs {
            HStack(spacing: 5) {
                Image(systemName: "headphones").font(.system(size: 11)).accessibilityHidden(true)
                Text(listened.formatted()).fontWeight(.medium).monospacedDigit()
                Text("累计听歌")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func stat(_ label: LocalizedStringKey, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(count.map { $0.formatted() } ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func content(_ overview: UserOverview, width: CGFloat, tab: ProfileTab) -> some View {
        switch tab {
        case .playlists: ProfilePlaylistsView(userID: userID, availableWidth: width).id(userID)
        case .events: SocialEventsView(userID: userID).id(userID).frame(maxWidth: 760, alignment: .leading)
        case .feed: SocialEventsView(userID: nil).frame(maxWidth: 760, alignment: .leading)
        case .ranking:
            if !isSelf, overview.peopleCanSeeMyPlayRecord == false {
                EmptyStateView(icon: "lock", title: "听歌排行未公开").frame(minHeight: 180)
            } else { UserRankingView(userID: userID).id(userID) }
        }
    }

    private func load(force: Bool = true) async {
        guard let session = account.socialSession, let scope = account.offlineScope else { overview = nil; return }
        generation += 1
        let ticket = generation
        loading = true
        error = nil
        defer { if ticket == generation { loading = false } }
        do {
            let key = "profile-overview:\(userID)"
            if overviewSession != session || overview == nil,
               let cached = await PageDataCache.shared.load(UserOverview.self, key: key, scope: scope) {
                guard ticket == generation, session == account.socialSession, scope == account.offlineScope, !Task.isCancelled else { return }
                overview = cached.value
                overviewSession = session
            }
            let value = try await PageDataCache.shared.fetch(UserOverview.self, key: key, scope: scope,
                                                            maxAge: 60, force: force, session: session) {
                let value = try await NeteaseAPI.userOverview(uid: userID)
                guard session == account.socialSession, scope == account.offlineScope, !Task.isCancelled else { throw CancellationError() }
                return value
            }
            guard ticket == generation, session == account.socialSession, scope == account.offlineScope, !Task.isCancelled else { return }
            overview = value
            overviewSession = session
            error = nil
        } catch {
            guard ticket == generation, session == account.socialSession, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct ProfilePlaylistsView: View {
    let userID: Int
    let availableWidth: CGFloat
    @StateObject private var model: SocialPageModel<PlaylistSummary>
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @State private var saved = false

    init(userID: Int, availableWidth: CGFloat) {
        self.userID = userID
        self.availableWidth = availableWidth
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "profile-playlists:\(userID)") { try await NeteaseAPI.socialPlaylists(uid: userID, cursor: $0) })
    }
    private var displayed: [PlaylistSummary] {
        model.items.filter { saved ? $0.creator?.userId != userID : $0.creator?.userId == userID }
    }
    var body: some View {
        let columns = max(2, Int((availableWidth + 20) / 170))
        let size = max(1, (availableWidth - CGFloat(columns - 1) * 20) / CGFloat(columns))
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 5) {
                SocialFilterButton(title: "创建的歌单", selected: !saved,
                                   count: model.hasLoaded && !model.hasMore ? model.items.filter { $0.creator?.userId == userID }.count : nil) { saved = false }
                SocialFilterButton(title: "收藏的歌单", selected: saved,
                                   count: model.hasLoaded && !model.hasMore ? model.items.filter { $0.creator?.userId != userID }.count : nil) { saved = true }
            }.padding(.leading, -11)
            if model.session == account.socialSession {
                if model.hasLoaded, displayed.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "暂无歌单").frame(minHeight: 180)
                }
                // Match each cover to its actual column width, keeping the
                // outer edges aligned as the window changes size.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns),
                          alignment: .leading, spacing: 24) {
                    ForEach(displayed) { playlist in
                        ProfilePlaylistCard(playlist: playlist, size: size) {
                            openDestination(.playlist(playlist.id))
                        }
                    }
                }
                SocialPageFooter(model: model)
            }
        }.task(id: account.socialSession) { await model.refresh(force: false) }
    }
}

private struct ProfilePlaylistCard: View {
    let playlist: PlaylistSummary
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(Int(size * 2)))
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                Text(playlist.name).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    if playlist.privacy != 0 { Image(systemName: "lock.fill").font(.system(size: 9)) }
                    Text("\(playlist.trackCount) 首")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(width: size, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(InteractiveCardStyle(showShadow: false, hoverScale: 1, pressScale: 0.99))
    }
}

struct SocialPeopleView: View {
    let userID: Int
    let followers: Bool
    @StateObject private var model: SocialPageModel<UserProfile>
    @EnvironmentObject private var account: AccountStore

    init(userID: Int, followers: Bool) {
        self.userID = userID; self.followers = followers
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "profile-people:\(userID):\(followers)") { try await NeteaseAPI.socialUsers(uid: userID, followers: followers, cursor: $0) })
    }
    var body: some View {
        Group {
            if account.socialSession == nil { SocialLoginPrompt() }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(followers ? "粉丝" : "关注的人").font(.system(size: 24, weight: .semibold))
                            Spacer()
                            SocialRefreshButton(loading: model.isLoading) { Task { await model.refresh() } }
                        }.padding(.bottom, 24)
                        if model.session == account.socialSession {
                            ForEach(model.items) { user in
                                SocialUserRow(user: user)
                                Divider().opacity(0.3).padding(.leading, 64)
                            }
                            if model.hasLoaded, model.items.isEmpty {
                                EmptyStateView(icon: "person.2", title: "暂无用户").frame(minHeight: 200)
                            }
                            SocialPageFooter(model: model)
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(Theme.Layout.contentInset)
                }
            }
        }
        .navigationTitle(followers ? "粉丝" : "关注的人")
        .task(id: account.socialSession) { await model.refresh(force: false) }
    }
}

struct SocialEventsView: View {
    let userID: Int?
    @StateObject private var model: SocialPageModel<SocialEvent>
    @EnvironmentObject private var account: AccountStore

    init(userID: Int?) {
        self.userID = userID
        _model = StateObject(wrappedValue: SocialPageModel(cacheKey: "profile-events:\(userID.map(String.init) ?? "feed")") { try await NeteaseAPI.socialEvents(uid: userID, cursor: $0) })
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if model.session == account.socialSession {
                ForEach(model.items) { event in
                    SocialEventRow(event: event)
                    Divider().opacity(0.3).padding(.leading, 48)
                }
                if model.hasLoaded, model.items.isEmpty {
                    EmptyStateView(icon: "text.bubble", title: "暂无动态").frame(minHeight: 180)
                }
                SocialPageFooter(model: model)
            }
        }.task(id: account.socialSession) { await model.refresh(force: false) }
    }
}

private struct SocialEventRow: View {
    let event: SocialEvent
    @Environment(\.openDestination) private var openDestination
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
          Button { openDestination(.profile(event.user.userId)) } label: { SocialAvatar(user: event.user, size: 36) }
              .buttonStyle(.plain).accessibilityLabel(Text(event.user.nickname))
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(event.user.nickname) { openDestination(.profile(event.user.userId)) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                SocialTime(milliseconds: event.eventTime)
            }
            if let payload = event.payload {
                if !payload.text.isEmpty {
                    Text(payload.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let resource = payload.resource, let kind = payload.resourceKind { SocialResourceLink(resource: resource, kind: kind) }
            }
            if let forwarded = event.forwardedContent {
                VStack(alignment: .leading, spacing: 8) {
                    if let user = event.payload?.event?.user { Text(user.nickname).font(.system(size: 12, weight: .medium)) }
                    Text(forwarded.text).font(.system(size: 12)).textSelection(.enabled)
                    if let resource = forwarded.resource, let kind = forwarded.resourceKind { SocialResourceLink(resource: resource, kind: kind) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }
            if let pictures = event.pics, !pictures.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(pictures.prefix(9).enumerated()), id: \.offset) { _, picture in
                        CachedAsyncImage(url: (picture.squareUrl ?? picture.originUrl).flatMap(URL.init(string:)))
                            .frame(height: 130).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            HStack(spacing: 16) {
                Label((event.info?.likedCount ?? 0).formatted(), systemImage: "heart")
                Label((event.info?.commentCount ?? 0).formatted(), systemImage: "text.bubble")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }.padding(.vertical, 8)
    }
}

private struct UserRankingView: View {
    let userID: Int
    @EnvironmentObject private var account: AccountStore
    @State private var week = true
    @State private var records: [PlayRecordItem] = []
    @State private var loadedWeek: Bool?
    @State private var generation = 0
    @State private var session: String?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                SocialFilterButton(title: "最近一周", selected: week) { week = true }
                SocialFilterButton(title: "所有时间", selected: !week) { week = false }
            }.padding(.leading, -11)
            if session == account.socialSession, loadedWeek == week {
                ForEach(Array(records.enumerated()), id: \.element.song.id) { index, record in
                    TrackRow(track: record.song, index: index + 1, totalCount: records.count,
                             style: .compact, trailingText: String(localized: "\(record.playCount) 次")) {
                        PlayerService.shared.play(tracks: records.map(\.song), source: .none, startAt: record.song)
                    }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if let error { ErrorStateView(message: error) { Task { await load() } } }
            else if records.isEmpty { EmptyStateView(icon: "chart.bar", title: "暂无播放记录").frame(minHeight: 180) }
        }
        .task(id: "\(account.socialSession ?? "guest"):\(week)") { await load(force: false) }
    }
    private func load(force: Bool = true) async {
        guard let binding = account.socialSession, let scope = account.offlineScope else { records = []; return }
        generation += 1
        let ticket = generation
        error = nil; loading = true
        let requestedWeek = week
        defer { if ticket == generation { loading = false } }
        if session != binding || loadedWeek != requestedWeek { records = [] }
        let key = "records:\(userID):\(requestedWeek)"
        if let cached = await PageDataCache.shared.load([PlayRecordItem].self, key: key, scope: scope) {
            guard ticket == generation, binding == account.socialSession, requestedWeek == week, scope == account.offlineScope, !Task.isCancelled else { return }
            records = cached.value; session = binding; loadedWeek = requestedWeek
        }
        do {
            let values = try await NeteaseAPI.cachedPlayRecords(uid: userID, week: requestedWeek, force: force)
            guard ticket == generation, binding == account.socialSession, requestedWeek == week, scope == account.offlineScope, !Task.isCancelled else { return }
            records = values; session = binding; loadedWeek = requestedWeek
        } catch {
            guard ticket == generation, binding == account.socialSession, requestedWeek == week, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
