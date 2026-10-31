import SwiftUI

// MARK: - 最近播放

struct RecentsView: View {
    @StateObject private var model = CachedContent<[PlayRecordItem]>()
    @State private var week = false

    @EnvironmentObject private var account: AccountStore
    private let player = PlayerService.shared

    var body: some View {
        TrackListScrollView(trackIDs: records.map { $0.song.id }, style: .compact, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                AdaptiveStack(horizontalMinimum: 380, spacing: 12) {
                    Picker("", selection: $week) {
                        Text("所有时间").tag(false)
                        Text("最近一周").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Button {
                        player.play(tracks: records.map(\.song), source: .none, context: .recents)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(records.isEmpty)
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("刷新").help("刷新")
                        .disabled(model.isRefreshing || account.authenticatedAccountID == nil)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let error = model.error, model.value == nil {
                    ErrorStateView(message: error) { Task { await load(force: true) } }
                        .frame(minHeight: 300)
                } else if records.isEmpty {
                    EmptyStateView(icon: "clock", title: "暂无播放记录")
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
            recordList(layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("最近播放")
        .task(id: "\(account.socialSession ?? "guest"):\(week)") {
            await load()
        }
    }

    @ViewBuilder
    private func recordList(layout: TrackListView.Layout) -> some View {
        switch layout {
        case .stack:
            LazyVStack(spacing: 1) {
                ForEach(Array(records.enumerated()), id: \.element.song.id) { index, _ in recordRow(at: index) }
            }
        case .singleRow(let index):
            recordRow(at: index)
        }
    }

    private func recordRow(at index: Int) -> some View {
        let record = records[index]
        return TrackRow(
            track: record.song,
            index: index + 1,
            totalCount: records.count,
            style: .compact,
            trailingText: String(localized: "\(record.playCount) 次")
        ) {
            player.play(tracks: records.map(\.song), source: .none, startAt: record.song,
                        context: .recents)
        }
    }

    private var records: [PlayRecordItem] {
        model.scope == account.offlineScope && account.authenticatedAccountID != nil ? model.value ?? [] : []
    }

    private func load(force: Bool = false) async {
        let uid = account.authenticatedAccountID
        let session = account.socialSession
        let scope = uid == nil ? nil : account.offlineScope
        let requestedWeek = week
        await model.load(key: "records:\(uid ?? 0):\(requestedWeek)", scope: scope, session: session,
            maxAge: 60, force: force,
            current: { account.offlineScope == scope && account.socialSession == session && week == requestedWeek }) {
                guard let uid else { throw NeteaseAPIError.needLogin }
                return try await NeteaseAPI.playRecords(uid: uid, week: requestedWeek)
            }
    }
}

// MARK: - 音乐云盘

struct CloudView: View {
    @ObservedObject private var model = CloudContent.shared
    @EnvironmentObject private var account: AccountStore

    private let player = PlayerService.shared

    var body: some View {
        let displayed = tracks
        TrackListScrollView(trackIDs: displayed.map(\.id), style: .compact, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                AdaptiveStack(horizontalMinimum: 440, spacing: 12) {
                    if let sizeInfo {
                        Text(sizeInfo)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        player.play(tracks: tracks, source: .cloud, context: .cloud)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(displayed.isEmpty)
                    Button { Task { await model.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("刷新").help("刷新")
                        .disabled(model.isRefreshing || account.authenticatedAccountID == nil)
                    if model.isRefreshing, !model.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let message = model.errorMessage, model.snapshot == nil {
                    ErrorStateView(message: message) { Task { await model.load(force: true) } }
                        .frame(minHeight: 300)
                } else if displayed.isEmpty {
                    EmptyStateView(icon: "icloud", title: "云盘还没有歌曲",
                                   subtitle: "在网易云音乐客户端上传的歌曲会出现在这里")
                        .frame(minHeight: 300)
                }
                if let message = model.errorMessage, model.snapshot != nil {
                    HStack(spacing: 8) {
                        Text(message).foregroundStyle(.secondary)
                        Button("重试") { Task { await model.load(force: true) } }
                            .disabled(model.isRefreshing)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
            }
        } rows: { layout in
            TrackListView(tracks: displayed, style: .compact, source: .cloud, context: .cloud, layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("音乐云盘")
        .task(id: account.socialSession) { await model.load() }
    }

    private var tracks: [Track] {
        model.loadedScope == account.offlineScope ? model.tracks : []
    }

    private var sizeInfo: String? {
        guard model.loadedScope == account.offlineScope,
              let size = model.snapshot?.size, let max = model.snapshot?.maxSize, max > 0 else { return nil }
        let used = String(format: "%.1f", Double(size) / 1_073_741_824)
        let total = String(format: "%.0f", Double(max) / 1_073_741_824)
        return String(localized: "已使用 \(used) GB / \(total) GB")
    }
}
