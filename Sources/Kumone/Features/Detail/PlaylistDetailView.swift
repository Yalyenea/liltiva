import SwiftUI


struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @StateObject private var model: PlaylistContent
    @ObservedObject private var downloads = DownloadManager.shared
    // This page only sends playback commands; individual rows observe playback.
    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
    @State private var showFullDescription = false

    init(playlistID: Int, isLikedList: Bool = false, recommendationContext: RecommendationContext? = nil) {
        self.playlistID = playlistID
        self.isLikedList = isLikedList
        self.recommendationContext = recommendationContext
        _model = StateObject(wrappedValue: PlaylistContent(playlistID: playlistID))
    }

    private var isOwnPlaylist: Bool {
        model.detail?.creator?.userId == account.profile?.userId
    }







    var body: some View {
        ScrollViewReader { proxy in
            onlineContent
                .task(id: "\(playlistID):\(account.offlineScope ?? ""):\(downloads.network.isKnown):\(downloads.network.connected)") {
                    await loadPlaylist()
                }
                .toolbar {
                    if model.errorMessage != nil, downloads.network.connected, model.detail != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button { Task { await loadPlaylist() } } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel("重试")
                                .help("重试")
                        }
                    }
                }
        }
    }

    private func loadPlaylist() async {
        await model.load(allowNetwork: !downloads.network.isKnown || downloads.network.connected,
                         summary: account.userPlaylists.first { $0.id == playlistID })
    }

    @ViewBuilder
    private var onlineContent: some View {
        Group {
            if model.loadedScope == account.offlineScope, let detail = model.detail {
                let tracks = model.filteredTracks
                TrackTable(
                    trackIDs: tracks.map(\.id),
                    header: AnyView(regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                        .padding(.bottom, 20)),
                    footer: AnyView(VStack(spacing: 20) {
                        playlistStatus(detail)
                        PlayerClearanceSpacer()
                    }.padding(.top, 20)),
                    footerHeight: desktopFooterHeight(detail)
                ) { index in
                    AnyView(trackList(tracks, layout: .singleRow(index))
                        .padding(.horizontal, Theme.Layout.contentInset - 10))
                }
            } else {
                ScrollView { playlistContents }
            }
        }
        .clipped()
        .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
    }

    private func desktopFooterHeight(_ detail: PlaylistDetail) -> CGFloat {
        let clearance = Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin + 20
        if model.isLoading || model.isLoadingMore { return clearance + 60 }
        if model.tracks.isEmpty { return clearance + 100 }
        if model.tracks.count < detail.trackCount { return clearance + 40 }
        return clearance
    }

    private func trackList(_ tracks: [Track], layout: TrackListView.Layout = .stack) -> some View {
        TrackListView(
            tracks: tracks,
            privileges: model.privileges,
            source: .playlist(playlistID),
            context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
            removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
            onRemoved: { track in Task { await model.remove(track) } },
            recommendationContext: recommendationContext,
            onRecommendationReduced: { model.replaceRecommendation($0, with: $1) },
            layout: layout
        )
    }

    @ViewBuilder
    private var playlistContents: some View {
        if model.loadedScope == account.offlineScope, let detail = model.detail {
            let filteredTracks = model.filteredTracks


                    regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)




            trackList(filteredTracks)
                .padding(.horizontal, Theme.Layout.contentInset - 10)

            playlistStatus(detail)
        } else if model.isLoading {
            loadingHeader
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await loadPlaylist() }
            }
            .frame(minHeight: 400)
        } else {
            EmptyStateView(icon: "music.note.list", title: "联网后载入歌曲")
                .frame(minHeight: 400)
        }
        PlayerClearanceSpacer()
    }

    @ViewBuilder
    private func playlistStatus(_ detail: PlaylistDetail) -> some View {
        if model.isLoading || model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 12)
        } else if model.tracks.isEmpty {
            Text(detail.trackCount == 0 ? String(localized: "歌单暂无歌曲") : String(localized: "联网后载入歌曲"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if model.tracks.count < detail.trackCount {
            Text("已载入 \(model.tracks.count)/\(detail.trackCount) 首")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Layout.contentInset)
        }

    }

    // MARK: - Compact (Mobile) Header



    // MARK: - Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        AdaptiveStack(horizontalMinimum: 620, spacing: 20) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512))
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        AdaptiveStack(horizontalMinimum: 540, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    player.play(
                        tracks: playable, source: .playlist(playlistID),
                        context: .playlist(id: playlistID, name: detail.name))
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(playable.isEmpty)

                if isLikedList {
                    Button {
                        startHeartbeat()
                    } label: {
                        Label("心动模式", systemImage: "heart.circle")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.pressable)
                } else if !isOwnPlaylist, account.isLoggedIn {
                    Button {
                        toggleSubscribe(detail)
                    } label: {
                        Label(
                            detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                            systemImage: detail.subscribed ? "checkmark" : "plus"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }

                downloadButton(detail)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ShortcutSearchField(text: $model.filter, placeholder: String(localized: "搜索歌单内歌曲"),
                                    isPlaylistSearch: true)
                    .frame(minWidth: 100)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private var playable: [Track] {
        let tracks = model.orderedTracks
        return tracks.filter { track in
            downloads.offlineTracksByID[track.id] != nil || track.playability(privilege: model.privileges[track.id],
                           isLoggedIn: account.isLoggedIn,
                           vipType: account.vipType) == .playable
        }
    }

    private func startHeartbeat() {
        Task {
            guard let seed = playable.randomElement() else { return }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed.id, playlistID: playlistID)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(playlistID), context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func toggleSubscribe(_ detail: PlaylistDetail) {
        Task {
            do {
                try await NeteaseAPI.subscribePlaylist(id: detail.id, subscribe: !detail.subscribed)
                model.detail?.subscribed.toggle()
                await account.refreshLibrary()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func downloadButton(_ detail: PlaylistDetail, compact: Bool = false) -> some View {
        DownloadCollectionButton(tracks: model.tracks, owner: "playlist:\(playlistID)", name: detail.name,
                                 enabled: model.canDownloadAll, compact: compact)
            .accessibilityHint("等待歌单完整加载后下载全部歌曲")
    }

    private var loadingHeader: some View {
        AdaptiveStack(horizontalMinimum: 620, spacing: 20) {
            SkeletonView(cornerRadius: Theme.Radius.large)
                .frame(width: 160, height: 160)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: 220, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 16)
    }
}
