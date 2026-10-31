import SwiftUI

struct DailySongsView: View {
    @StateObject private var model = CachedContent<[Track]>()

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let displayed = tracks
        TrackListScrollView(trackIDs: displayed.map(\.id)) {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 16)
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if account.authenticatedAccountID == nil {
                    ErrorStateView(message: String(localized: "登录后才能查看每日推荐")) { Task { await load() } }
                        .frame(minHeight: 300)
                } else if let errorMessage = model.error, model.value == nil {
                    ErrorStateView(message: errorMessage) { Task { await load(force: true) } }
                        .frame(minHeight: 300)
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "calendar.badge.clock", title: "暂无每日推荐",
                                   subtitle: "多听几首歌培养口味，每天 6:00 更新")
                        .frame(minHeight: 300)
                }
                if let error = model.error, model.value != nil {
                    HStack {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { Task { await load(force: true) } }
                    }.font(.callout).padding(.horizontal, Theme.Layout.contentInset)
                }
            }
        } rows: { layout in
            TrackListView(
                tracks: displayed,
                source: .daily,
                context: .daily,
                recommendationContext: .daily,
                onRecommendationReduced: { rejected, replacement in
                    var updated = tracks
                    updated.replaceRecommendation(rejected, with: replacement)
                    let scope = account.offlineScope, session = account.socialSession
                    Task {
                        guard scope == account.offlineScope, session == account.socialSession else { return }
                        do { try await model.replace(updated) }
                        catch { ToastCenter.shared.show(error.localizedDescription) }
                    }
                },
                layout: layout
            )
            .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("每日推荐")
        .task(id: account.socialSession) { await load() }
    }

    private var header: some View {
        AdaptiveStack(horizontalMinimum: 480, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 26, weight: .medium))
                    Text(dateString)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("每日推荐")
                    .font(.title.weight(.bold))
                Text("根据你的音乐口味 · 每天 6:00 更新")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新").help("刷新")
                .disabled(model.isRefreshing || account.authenticatedAccountID == nil)
            Button {
                player.play(tracks: tracks, source: .daily, context: .daily)
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(tracks.isEmpty)
        }
        .padding(.vertical, 12)
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return fmt.string(from: .now)
    }

    private var tracks: [Track] {
        model.scope == account.offlineScope && account.authenticatedAccountID != nil ? model.value ?? [] : []
    }

    private func load(force: Bool = false) async {
        let session = account.socialSession
        let scope = account.authenticatedAccountID == nil ? nil : account.offlineScope
        await model.load(key: NeteaseAPI.dailyCacheKey(), scope: scope, session: session,
            maxAge: NeteaseAPI.dailyCacheMaxAge(), force: force,
            current: { account.offlineScope == scope && account.socialSession == session }) {
                try await NeteaseAPI.dailyRecommendSongs()
            }
    }
}
