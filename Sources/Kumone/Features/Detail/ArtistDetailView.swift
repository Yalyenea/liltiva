import SwiftUI

struct ArtistDetailView: View {
    let artistID: Int

    @State private var artist: ArtistSummary?
    @State private var hotSongs: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var epsAndSingles: [AlbumSummary] = []
    @State private var similar: [ArtistSummary] = []
    @State private var isFollowed = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var contentIdentity: String?
    @State private var isFollowing = false
    @ObservedObject private var downloads = DownloadManager.shared

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore



    var body: some View {
        TrackListScrollView(trackIDs: hotSongs.map(\.id), style: .compact, spacing: 26) {
            VStack(alignment: .leading, spacing: 26) {
                if let artist {

                        regularHeader(artist).padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                    if let errorMessage {
                        HStack {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("重试") { Task { await load(force: true) } }
                                .disabled(isRefreshing)
                        }.font(.caption).padding(.horizontal, Theme.Layout.contentInset)
                    }

                    if !hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲")
                            .padding(.horizontal, Theme.Layout.contentInset)
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load(force: true) } }
                        .frame(minHeight: 400)
                }
            }
        } rows: { layout in
            TrackListView(tracks: hotSongs, style: .compact, source: .artist(artistID),
                          context: artist.map { .artist(id: artistID, name: $0.name) }, layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: 26) {
                if !albums.isEmpty {
                    SectionHeader(title: "专辑")
                        .padding(.horizontal, Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                            ForEach(albums) { album in
                                albumCard(album)
                            }
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                        }
                    }
                }

                if !epsAndSingles.isEmpty {
                    SectionHeader(title: "EP 与单曲")
                        .padding(.horizontal, Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                            ForEach(epsAndSingles) { album in
                                albumCard(album)
                            }
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                        }
                    }
                }

                if !similar.isEmpty {
                    SectionHeader(title: "相似歌手")
                        .padding(.horizontal, Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                            ForEach(similar) { sim in
                                NavigationLink(value: Destination.artist(sim.id)) {
                                    VStack(spacing: 8) {
                                        CachedAsyncImage(url: sim.picUrl?.resizedImageURL(256))
                                            .frame(width: 100, height: 100)
                                            .clipShape(Circle())
                                        Text(sim.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 100)
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
        .navigationTitle(artist?.name ?? String(localized: "歌手"))
        .task(id: "\(artistID):\(account.offlineScope ?? "unbound"):\(account.socialSession ?? "guest"):\(downloads.network.connected)") {
            await load()
        }
        .toolbar {
            if errorMessage != nil, downloads.network.connected, artist != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重试")
                        .help("重试")
                }
            }
        }
    }

    private func load(force: Bool = false) async {
        let scope = account.offlineScope
        let session = NeteaseClient.shared.authenticationFingerprint
        let identity = "\(artistID):\(scope ?? "unbound"):\(session ?? "guest")"
        // A reconnect cannot race a follow operation that is still being committed.
        guard !isFollowing || contentIdentity != identity else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if contentIdentity != identity {
            artist = nil
            hotSongs = []
            albums = []
            epsAndSingles = []
            similar = []
            isFollowed = false
            isFollowing = false
            contentIdentity = identity
        }
        isLoading = artist == nil
        isRefreshing = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                isRefreshing = false
            }
        }
        if let scope {
            let cached = await PageDataCache.shared.load(NeteaseAPI.ArtistResponse.self, key: "artist:\(artistID)", scope: scope)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            if let cached {
                artist = cached.value.artist
                hotSongs = cached.value.hotSongs
                isFollowed = cached.value.artist.followed
                isLoading = false
            }
            let cachedAlbums = await PageDataCache.shared.load([AlbumSummary].self, key: "artist-albums:\(artistID):60", scope: scope)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            if let cachedAlbums { applyAlbums(cachedAlbums.value) }
            let cachedSimilar = await PageDataCache.shared.load([ArtistSummary].self, key: "artist-similar:\(artistID)", scope: scope)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            if let cachedSimilar { similar = cachedSimilar.value }
        }
        if !downloads.network.connected {
            if artist == nil { errorMessage = URLError(.notConnectedToInternet).localizedDescription }
            return
        }
        do {
            let response = try await NeteaseAPI.cachedArtist(id: artistID, force: force)
            guard isCurrent(generation, scope: scope, session: session) else { return }
            artist = response.artist
            hotSongs = response.hotSongs
            isFollowed = response.artist.followed
            isLoading = false

            do {
                let result = try await NeteaseAPI.cachedArtistAlbums(id: artistID, limit: 60, force: force)
                guard isCurrent(generation, scope: scope, session: session) else { return }
                applyAlbums(result)
            } catch {
                guard isCurrent(generation, scope: scope, session: session) else { return }
                errorMessage = error.localizedDescription
            }
            if account.isLoggedIn, let scope {
                do {
                    let result = try await PageDataCache.shared.fetch(
                        [ArtistSummary].self, key: "artist-similar:\(artistID)", scope: scope,
                        maxAge: 300, force: force, session: session,
                        loader: {
                            guard account.offlineScope == scope, NeteaseClient.shared.authenticationFingerprint == session else { throw CancellationError() }
                            let artists = try await NeteaseAPI.similarArtists(id: artistID)
                            // Recheck after suspension before PageDataCache persists a personalized response.
                            guard account.offlineScope == scope, NeteaseClient.shared.authenticationFingerprint == session else { throw CancellationError() }
                            return artists
                        }
                    )
                    guard isCurrent(generation, scope: scope, session: session) else { return }
                    similar = result
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

    private func applyAlbums(_ items: [AlbumSummary]) {
        albums = items.filter { $0.size > 1 }
        epsAndSingles = items.filter { $0.size <= 1 }
    }

    // MARK: - Compact Header



    // MARK: - Regular Header

    private func regularHeader(_ artist: ArtistSummary) -> some View {
        AdaptiveStack(horizontalMinimum: 520, spacing: 20) {
            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(512))
                .frame(width: 144, height: 144)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                Text("歌手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                if !artist.alias.isEmpty {
                    Text(artist.alias.joined(separator: " / "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: hotSongs, source: .artist(artistID),
                                context: .artist(id: artistID, name: artist.name))
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)

                    if account.isLoggedIn {
                        Button {
                            toggleFollow()
                        } label: {
                            Label(isFollowed ? String(localized: "已关注") : String(localized: "关注"),
                                  systemImage: isFollowed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .disabled(isRefreshing || isFollowing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.publishYear
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private func toggleFollow() {
        guard !isFollowing, !isRefreshing, let scope = account.offlineScope else { return }
        let session = NeteaseClient.shared.authenticationFingerprint
        let generation = loadGeneration
        let followed = !isFollowed
        isFollowing = true
        Task {
            defer { if isCurrent(generation, scope: scope, session: session) { isFollowing = false } }
            do {
                guard isCurrent(generation, scope: scope, session: session) else { return }
                try await NeteaseAPI.subscribeArtist(id: artistID, subscribe: followed)
                guard isCurrent(generation, scope: scope, session: session) else { return }
                isFollowed = followed
                if var updated = artist {
                    updated.followed = followed
                    artist = updated
                    try? await PageDataCache.shared.save(
                        NeteaseAPI.ArtistResponse(artist: updated, hotSongs: hotSongs),
                        key: "artist:\(artistID)", scope: scope
                    )
                }
                guard isCurrent(generation, scope: scope, session: session) else { return }
                ToastCenter.shared.show(isFollowed ? String(localized: "已关注歌手") : String(localized: "已取消关注"))
                await account.refreshSublists(force: true)
            } catch {
                guard isCurrent(generation, scope: scope, session: session) else { return }
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        AdaptiveStack(horizontalMinimum: 520, spacing: 20) {
            SkeletonView(cornerRadius: 90)
                .clipShape(Circle())
                .frame(width: 144, height: 144)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 16)
    }
}
