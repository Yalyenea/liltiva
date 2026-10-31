import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    /// The personalized radar family — global playlist IDs whose content is
    /// generated per logged-in account (same list YesPlayMusic special-cases).
    static let radarPlaylistIDs = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    struct RadarPlaylist: Identifiable, Hashable, Codable {
        let id: Int
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    struct Loaders {
        var recommendations: @MainActor (Bool) async throws -> [PlaylistSummary]
        var toplists: @MainActor () async throws -> [ToplistItem]
        var albums: @MainActor () async throws -> [AlbumSummary]
        var artists: @MainActor () async throws -> [ArtistSummary]
        var radar: @MainActor () async throws -> [RadarPlaylist]
        var daily: @MainActor (Bool) async throws -> [Track]

        @MainActor static var live: Self {
            Self(recommendations: { try await HomeViewModel.fetchRecommendPlaylists(loggedIn: $0) },
                 toplists: { try await NeteaseAPI.toplists() },
                 albums: { try await NeteaseAPI.newAlbums(limit: 20) },
                 artists: { try await NeteaseAPI.topArtists() },
                 radar: { try await HomeViewModel.fetchRadarPlaylists() },
                 daily: { try await NeteaseAPI.cachedDailyRecommendSongs(force: $0) })
        }
    }

    @Published var state: State = .idle
    @Published var recommendPlaylists: [PlaylistSummary] = []
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?
    @Published var refreshError: String?
    @Published private(set) var isRefreshing = false
    private var context: DiscoveryCacheContext?
    private var generation = 0
    private let cache: PageDataCache
    private let currentContext: @MainActor () -> DiscoveryCacheContext
    private let loaders: Loaders
    var matchesCurrentAccount: Bool { context == currentContext() }
    var isEmpty: Bool { !hasContent }

    init(cache: PageDataCache = .shared,
         currentContext: @escaping @MainActor () -> DiscoveryCacheContext = { .current },
         loaders: Loaders? = nil) {
        self.cache = cache
        self.currentContext = currentContext
        self.loaders = loaders ?? .live
    }

    func load(loggedIn: Bool, force: Bool = false) async {
        let binding = currentContext()
        // Each appearance owns its completion, even when a same-account visit
        // joins a cache request still running from the previous appearance.
        generation += 1
        if context != binding {
            context = binding
            recommendPlaylists = []; radarPlaylists = []; toplists = []
            newAlbums = []; topArtists = []; dailyFirstCover = nil
            state = .idle
        }
        let ticket = generation
        isRefreshing = true
        defer { if ticket == generation, context == binding { isRefreshing = false } }
        refreshError = nil
        if !hasContent { state = .loading }

        async let playlists: Void = section([PlaylistSummary].self, key: "home.recommendations", context: binding,
            ticket: ticket, force: force, apply: { self.recommendPlaylists = $0 }) {
                try await self.loaders.recommendations(loggedIn)
            }
        async let lists: Void = section([ToplistItem].self, key: DiscoveryCache.toplistsKey, publicData: true,
            context: binding, ticket: ticket, force: force, apply: {
                self.toplists = $0.filter { [19_723_756, 3_779_629, 2_884_035, 3_778_678, 60198].contains($0.id) }
            }) { try await self.loaders.toplists() }
        async let albums: Void = section([AlbumSummary].self, key: "home.new-albums", publicData: true,
            context: binding, ticket: ticket, force: force, apply: { self.newAlbums = $0 }) {
                try await self.loaders.albums()
            }
        async let artists: Void = section([ArtistSummary].self, key: "home.top-artists", publicData: true,
            context: binding, ticket: ticket, force: force, apply: { self.topArtists = Array($0.prefix(6)) }) {
                try await self.loaders.artists()
            }
        async let radar: Void = loadPersonalSections(loggedIn: loggedIn, context: binding, ticket: ticket, force: force)
        _ = await (playlists, lists, albums, artists, radar)
        guard context == binding, ticket == generation, binding == currentContext() else { return }
        if !hasContent, let refreshError { state = .error(refreshError) }
        else { state = .loaded }
    }

    func reload(loggedIn: Bool) async {
        await load(loggedIn: loggedIn, force: true)
    }

    private var hasContent: Bool {
        !recommendPlaylists.isEmpty || !radarPlaylists.isEmpty || !toplists.isEmpty || !newAlbums.isEmpty || !topArtists.isEmpty
    }

    private func section<Item: Codable & Sendable>(_ type: [Item].Type, key: String, publicData: Bool = false,
        context binding: DiscoveryCacheContext, ticket: Int, force: Bool,
        apply: @escaping @MainActor ([Item]) -> Void,
        loader: @escaping @MainActor () async throws -> [Item]) async {
        let cached = await cache.load(type, key: key, scope: publicData ? "public" : binding.scope)
        guard context == binding, ticket == generation, binding == currentContext() else { return }
        if let cached {
            apply(cached.value)
            state = .loaded
        }
        do {
            let currentContext = self.currentContext
            guard binding.scope != "pending", binding == currentContext() else { throw CancellationError() }
            let values = try await cache.fetch(type, key: key, scope: publicData ? "public" : binding.scope,
                maxAge: 30 * 60, force: force, session: binding.session) {
                    guard binding.scope != "pending", binding == currentContext() else { throw CancellationError() }
                    let values = try await loader()
                    guard binding == currentContext() else { throw CancellationError() }
                    return values
                }
            guard context == binding, ticket == generation, binding == currentContext() else { return }
            apply(values)
            if hasContent { state = .loaded }
        } catch is CancellationError {
        } catch {
            guard context == binding, ticket == generation, binding == currentContext() else { return }
            refreshError = error.localizedDescription
        }
    }

    private func loadPersonalSections(loggedIn: Bool, context binding: DiscoveryCacheContext, ticket: Int, force: Bool) async {
        guard loggedIn else { return }
        async let radar: Void = section([RadarPlaylist].self, key: "home.radar", context: binding,
            ticket: ticket, force: force, apply: { self.radarPlaylists = $0 }) {
                try await self.loaders.radar()
            }
        if let cached = await cache.load([Track].self, key: NeteaseAPI.dailyCacheKey(), scope: binding.scope),
           context == binding, ticket == generation, binding == currentContext() {
            dailyFirstCover = cached.value.first?.album.picUrl
        }
        if let daily = try? await loaders.daily(force),
           context == binding, ticket == generation, binding == currentContext() {
            dailyFirstCover = daily.first?.album.picUrl
        }
        await radar
    }

    private static func fetchRadarPlaylists() async throws -> [RadarPlaylist] {
        let briefs = try await withThrowingTaskGroup(of: (Int, NeteaseAPI.PlaylistBrief.Body).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    (id, try await NeteaseAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: NeteaseAPI.PlaylistBrief.Body] = [:]
            for try await (id, brief) in group {
                byID[id] = brief
            }
            return byID
        }
        return Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            // Names arrive as "今天从《…》听起|私人雷达" — split into title/subtitle.
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? String(localized: "雷达歌单"))
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return RadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
    }

    private static func fetchRecommendPlaylists(loggedIn: Bool) async throws -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = NeteaseAPI.recommendResource()
            async let personalized = NeteaseAPI.personalizedPlaylists(limit: 30)
            let (head, tail) = try await (recommend, personalized)
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return try await NeteaseAPI.personalizedPlaylists(limit: 30)
    }
}

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @StateObject private var model = HomeViewModel.shared

    var body: some View {
        ScrollView {
            if !model.matchesCurrentAccount {
                loadingBody
            } else {
                switch model.state {
                case .idle, .loading:
                    loadingBody
                case .error(let message):
                    ErrorStateView(message: message) {
                        Task { await model.reload(loggedIn: account.isLoggedIn) }
                    }
                    .frame(minHeight: 400)
                case .loaded:
                    loadedBody
                }
            }
        }
        .navigationTitle("推荐")
        .task(id: account.socialSession) {
            await model.load(loggedIn: account.isLoggedIn)
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 32) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonView(cornerRadius: Theme.Radius.large)
                            .frame(width: 230, height: 132)
                    }
                }
            }
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 34) {
            if model.isEmpty, model.refreshError == nil, !model.isRefreshing {
                EmptyStateView(icon: "music.note.list", title: "暂无推荐内容")
                    .frame(minHeight: 300)
            }
            if let message = model.refreshError {
                ErrorStateView(message: message) {
                    Task { await model.reload(loggedIn: account.isLoggedIn) }
                }
            }
            // Anonymous users go straight to recommended playlists;
            // the login entry lives in the sidebar / 我的 tab only.
            if account.isLoggedIn {
                featureCards
                    .padding(.top, 8)
            }

            if !model.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !model.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.radarPlaylists) { radar in
                        NavigationLink(value: Destination.radarPlaylist(radar.id)) {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle
                            ) {
                                playPlaylist(radar.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.toplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.toplists) { toplist in
                        NavigationLink(value: Destination.playlist(toplist.id)) {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.newAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "新碟上架")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    GeometryReader { geometry in
                        let size = Theme.Layout.fittedShelfCardSize(availableWidth: geometry.size.width, leadingInset: Theme.Layout.contentInset)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(model.newAlbums) { album in
                                    albumCard(album, size: size)
                                }
                            }
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .frame(height: Theme.Layout.coverShelfHeight)
                        }
                    }
                    .frame(height: Theme.Layout.coverShelfHeight)
                }
            }

            if !model.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }

            PlayerClearanceSpacer()
        }
        .padding(.vertical, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                if account.isLoggedIn {
                    NavigationLink(value: Destination.daily) {
                        FeatureCard(
                            title: "每日推荐",
                            subtitle: "根据你的口味生成",
                            icon: "calendar",
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.startFM()
                    } label: {
                        FeatureCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill"
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    Button {
                        startHeartbeatMode()
                    } label: {
                        FeatureCard(
                            title: "心动模式",
                            subtitle: "你的红心歌曲和相似推荐",
                            icon: "heart.circle.fill"
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        NavigationLink(value: Destination.playlist(playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount
            ) {
                playPlaylist(playlist.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary, size: CGFloat) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName,
                size: size
            ) {
                Task {
                    if let detail = try? await NeteaseAPI.cachedAlbum(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistCard(_ toplist: ToplistItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(384))
                    .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                Text(toplist.updateFrequency ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
            }
            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
            Text(toplist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Theme.Layout.cardSize, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func playPlaylist(_ id: Int) {
        Task {
            do { try await PlaylistPlayback.start(id: id) }
            catch { ToastCenter.shared.show(error.localizedDescription) }
        }
    }
}

// MARK: - Feature card

struct FeatureCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var showsDate = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.primary.opacity(0.04)

            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .offset(y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
        }
        .frame(width: 230, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var onPlay: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(8)
                    }
                }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: size, alignment: .leading)
            }
        }
        .frame(maxWidth: size, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var artwork: some View {
        CachedAsyncImage(url: coverURL)
            .frame(width: size, height: size)
    }
}
