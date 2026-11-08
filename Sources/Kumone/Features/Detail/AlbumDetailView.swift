import SwiftUI

struct AlbumDetailView: View {
    let albumID: Int

    @State private var album: AlbumDetail?
    @State private var tracks: [Track] = []
    @State private var otherAlbums: [AlbumSummary] = []
    @State private var isSubscribed = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var showFullDescription = false
    @State private var loadGeneration = 0
    @State private var contentIdentity: String?
    @State private var isSubscribing = false
    @ObservedObject private var downloads = DownloadManager.shared

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore



    /// Only a collection with songs to show may replace the online page,
    /// otherwise an empty list would hide the error and its retry button.
    private var savedCollectionID: String? {
        let id = "album:\(albumID)"
        return downloads.downloadedSongs(in: id).isEmpty ? nil : id
    }

    var body: some View {
        Group {
            if album == nil, let savedCollectionID, !downloads.network.connected || errorMessage != nil {
                DownloadedMusicView(collectionID: savedCollectionID)
            } else { onlineContent }
        }
        .task(id: "\(albumID):\(account.offlineScope ?? "unbound"):\(account.socialSession ?? "guest"):\(downloads.network.connected)") {
            await load()
        }
        .toolbar {
            if errorMessage != nil, downloads.network.connected, album != nil || savedCollectionID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重试")
                        .help("重试")
                }
            }
        }
    }

    private var onlineContent: some View {
        TrackListScrollView(trackIDs: tracks.map(\.id), spacing: 20) {
            if let album {

                    regularHeader(album).padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                    if let errorMessage {
                    HStack {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("重试") { Task { await load(force: true) } }
                            .disabled(isRefreshing)
                    }.font(.caption).padding(.horizontal, Theme.Layout.contentInset)
                    }

            } else if isLoading {
                loadingHeader
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load(force: true) } }
                    .frame(minHeight: 400)
            }
        } rows: { layout in
            TrackListView(tracks: tracks, source: .album(albumID),
                          context: album.map { .album(id: albumID, name: $0.name) }, layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: 20) {
                if !otherAlbums.isEmpty {
                    SectionHeader(title: "该歌手的其他专辑")
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 12)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                            ForEach(otherAlbums) { item in
                                NavigationLink(value: Destination.album(item.id)) {
                                    CoverCardBody(
                                        coverURL: item.picUrl?.resizedImageURL(384),
                                        title: item.name,
                                        subtitle: Formatters.date(fromMS: item.publishTime)
                                    )
                                }
                                .buttonStyle(.interactiveCard)
                            }
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(album?.name ?? String(localized: "专辑"))
    }

    private func load(force: Bool = false) async {
        let scope = account.offlineScope
        let session = NeteaseClient.shared.authenticationFingerprint
        let identity = "\(albumID):\(scope ?? "unbound"):\(session ?? "guest")"
        // A reconnect cannot race a subscription that is still being committed.
        guard !isSubscribing || contentIdentity != identity else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if contentIdentity != identity {
            album = nil
            tracks = []
            otherAlbums = []
            isSubscribed = false
            isSubscribing = false
            contentIdentity = identity
        }
        isLoading = album == nil
        isRefreshing = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                isRefreshing = false
            }
        }
        if let scope {
            let cached = await PageDataCache.shared.load(AlbumDetailResponse.self, key: "album:\(albumID)", scope: scope)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            if let cached {
                album = cached.value.album
                tracks = cached.value.songs
                isLoading = false
            }
            let subscription = await PageDataCache.shared.load(Bool.self, key: "album-subscription:\(albumID)", scope: scope)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            if let subscription { isSubscribed = subscription.value }
            if let artistID = album?.artist?.id {
                let cachedAlbums = await PageDataCache.shared.load([AlbumSummary].self, key: "artist-albums:\(artistID):12", scope: scope)
                guard isCurrent(generation, scope: scope, session: session) else { return }
                if let cachedAlbums { otherAlbums = cachedAlbums.value.filter { $0.id != albumID } }
            }
        }
        if !downloads.network.connected {
            if album == nil { errorMessage = URLError(.notConnectedToInternet).localizedDescription }
            return
        }
        do {
            let response = try await NeteaseAPI.cachedAlbum(id: albumID, force: force)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            album = response.album
            tracks = response.songs
            isLoading = false
            if let scope {
                do {
                    let subscribed = try await PageDataCache.shared.fetch(
                        Bool.self, key: "album-subscription:\(albumID)", scope: scope,
                        maxAge: 300, force: force, session: session,
                        loader: {
                            guard account.offlineScope == scope, NeteaseClient.shared.authenticationFingerprint == session else { throw CancellationError() }
                            let subscribed = try await NeteaseAPI.albumDynamic(id: albumID).isSub ?? false
                            // A response from a previous login cannot populate this account's disk cache.
                            guard account.offlineScope == scope, NeteaseClient.shared.authenticationFingerprint == session else { throw CancellationError() }
                            return subscribed
                        }
                    )
                    guard isCurrent(generation, scope: scope, session: session) else { return }
                    isSubscribed = subscribed
                } catch {
                    guard isCurrent(generation, scope: scope, session: session) else { return }
                    errorMessage = error.localizedDescription
                }
            }
            if let artistID = response.album.artist?.id {
                do {
                    let albums = try await NeteaseAPI.cachedArtistAlbums(id: artistID, limit: 12, force: force)
                    guard isCurrent(generation, scope: scope, session: session) else { return }
                    otherAlbums = albums.filter { $0.id != albumID }
                } catch {
                    guard isCurrent(generation, scope: scope, session: session) else { return }
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            guard isCurrent(generation, scope: scope, session: session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ generation: Int, scope: String?, session: String?) -> Bool {
        generation == loadGeneration && !Task.isCancelled
            && account.offlineScope == scope && NeteaseClient.shared.authenticationFingerprint == session
    }

    // MARK: - Compact Header



    // MARK: - Regular Header

    private func regularHeader(_ album: AlbumDetail) -> some View {
        AdaptiveStack(horizontalMinimum: 560, spacing: 20) {
            CachedAsyncImage(url: album.picUrl?.resizedImageURL(512))
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(album.subType?.isEmpty == false ? album.subType! : String(localized: "专辑"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(album.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let artist = album.artist {
                    NavigationLink(value: Destination.artist(artist.id)) {
                        Text(artist.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(tracks.count) 首 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = album.description, !description.isEmpty {
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
                        .popupSurface()
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: tracks, source: .album(albumID),
                                context: .album(id: albumID, name: album.name))
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)

                    DownloadCollectionButton(tracks: tracks, owner: "album:\(albumID)", name: album.name)

                    if account.isLoggedIn {
                        Button {
                            toggleSubscribe()
                        } label: {
                            Label(isSubscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                                  systemImage: isSubscribed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .disabled(isRefreshing || isSubscribing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalDuration: String {
        let totalMS = tracks.reduce(into: 0) { $0 += $1.durationMS }
        return Formatters.longDuration(TimeInterval(totalMS) / 1000)
    }

    private func toggleSubscribe() {
        guard !isSubscribing, !isRefreshing, let scope = account.offlineScope else { return }
        let session = NeteaseClient.shared.authenticationFingerprint
        let generation = loadGeneration
        let subscribed = !isSubscribed
        isSubscribing = true
        Task {
            defer { if isCurrent(generation, scope: scope, session: session) { isSubscribing = false } }
            do {
                guard isCurrent(generation, scope: scope, session: session) else { return }
                try await NeteaseAPI.subscribeAlbum(id: albumID, subscribe: subscribed)
                guard isCurrent(generation, scope: scope, session: session) else { return }
                isSubscribed = subscribed
                try? await PageDataCache.shared.save(subscribed, key: "album-subscription:\(albumID)", scope: scope)
                guard isCurrent(generation, scope: scope, session: session) else { return }
                ToastCenter.shared.show(isSubscribed ? String(localized: "已收藏专辑") : String(localized: "已取消收藏"))
                await account.refreshSublists(force: true)
            } catch {
                guard isCurrent(generation, scope: scope, session: session) else { return }
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        AdaptiveStack(horizontalMinimum: 560, spacing: 20) {
            SkeletonView(cornerRadius: Theme.Radius.large)
                .frame(width: 160, height: 160)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 16)
    }
}
