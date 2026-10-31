import SwiftUI

@MainActor
final class ExploreViewModel: ObservableObject {
    /// Shared so category selection and loaded pages survive sidebar switches.
    static let shared = ExploreViewModel()

    static let categories: [String] = [
        "全部", "推荐歌单", "精品歌单", "排行榜", "官方",
        "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
        "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
        "学习", "工作", "运动", "驾车", "夜晚",
    ]

    @Published var selectedCategory = "全部"
    @Published var playlists: [PlaylistSummary] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var error: String?
    private struct Page: Codable {
        var playlists: [PlaylistSummary] = []
        var offset = 0
        var before = 0
        var hasMore = true
    }
    private var page = Page()
    private var context: DiscoveryCacheContext?
    private var generation = 0
    private var failedPagination = false
    private var memory: [String: CachedPage<Page>] = [:]
    private var loadTask: Task<Void, Never>?
    var matchesCurrentAccount: Bool { context == .current }

    func activate() async {
        let binding = DiscoveryCacheContext.current
        if context != binding {
            context = binding
            generation += 1
            playlists = []; toplists = []; page = Page(); error = nil; isLoading = false
        }
        await loadSelected()
    }

    func select(_ category: String) {
        guard category != selectedCategory || playlists.isEmpty else { return }
        generation += 1
        selectedCategory = category
        playlists = []; toplists = []; page = Page(); error = nil; isLoading = false; hasMore = true
        loadTask?.cancel()
        loadTask = Task { await loadSelected() }
    }

    func retry() async {
        if failedPagination {
            error = nil
            await loadMore()
        } else {
            await loadSelected(force: true)
        }
    }

    private func isCurrent(_ binding: DiscoveryCacheContext, _ ticket: Int, _ category: String) -> Bool {
        binding == .current && context == binding && ticket == generation && selectedCategory == category
    }

    private func apply(_ page: Page) {
        self.page = page
        playlists = page.playlists
        hasMore = page.hasMore
    }

    private func loadSelected(force: Bool = false) async {
        guard !isLoading, let binding = context else { return }
        let ticket = generation
        let category = selectedCategory
        isLoading = true
        error = nil
        failedPagination = false
        defer { if isCurrent(binding, ticket, category) { isLoading = false } }
        do {
            if category == "排行榜" {
                if let cached = await PageDataCache.shared.load([ToplistItem].self, key: DiscoveryCache.toplistsKey, scope: "public"),
                   isCurrent(binding, ticket, category) { toplists = cached.value }
                let lists = try await DiscoveryCache.toplists(context: binding, force: force)
                guard isCurrent(binding, ticket, category) else { return }
                toplists = lists; hasMore = false
                return
            }
            let key = "explore.category.\(category)"
            let memoryKey = "\(binding.scope):\(key)"
            let cached: CachedPage<Page>?
            if let value = memory[memoryKey] { cached = value }
            else { cached = await PageDataCache.shared.load(Page.self, key: key, scope: binding.scope) }
            guard isCurrent(binding, ticket, category) else { return }
            if let cached { apply(cached.value) }
            let value = try await binding.fetch(Page.self, key: key, maxAge: 30 * 60, force: force) {
                    try await Self.fetchPage(category: category, previous: Page())
                }
            guard isCurrent(binding, ticket, category) else { return }
            apply(value)
            remember(value, key: memoryKey)
        } catch is CancellationError {
        } catch {
            if isCurrent(binding, ticket, category) { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore, error == nil, let binding = context else { return }
        guard !playlists.isEmpty else { await loadSelected(); return }
        let category = selectedCategory
        let ticket = generation
        let previous = page
        isLoading = true
        failedPagination = false
        defer { if isCurrent(binding, ticket, category) { isLoading = false } }
        do {
            try binding.validate()
            let value = try await Self.fetchPage(category: category, previous: previous)
            try binding.validate()
            guard isCurrent(binding, ticket, category) else { return }
            // Save the entire accumulated list with its cursor, so returning to
            // a category continues from the same page after navigation/relaunch.
            let key = "explore.category.\(category)"
            try await PageDataCache.shared.save(value, key: key, scope: binding.scope)
            guard isCurrent(binding, ticket, category) else { return }
            apply(value)
            remember(value, key: "\(binding.scope):\(key)")
        } catch is CancellationError {
        } catch {
            if isCurrent(binding, ticket, category) {
                failedPagination = true
                self.error = error.localizedDescription
            }
        }
    }

    private func remember(_ value: Page, key: String) {
        memory[key] = CachedPage(value: value, savedAt: .now)
        if memory.count > 32, let oldest = memory.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
            memory.removeValue(forKey: oldest)
        }
    }

    private static func fetchPage(category: String, previous: Page) async throws -> Page {
        var page = previous
        let items: [PlaylistSummary]
        switch category {
        case "推荐歌单":
            items = try await NeteaseAPI.personalizedPlaylists(limit: 100)
            page.hasMore = false
        case "精品歌单":
            let result = try await NeteaseAPI.highQualityPlaylists(before: previous.before)
            items = result.playlists
            page.before = result.lasttime ?? 0
            page.hasMore = (result.more ?? false) && page.before != previous.before
        default:
            let result = try await NeteaseAPI.topPlaylists(category: category, offset: previous.offset)
            items = result.playlists
            page.offset += items.count
            page.hasMore = (result.more ?? false) && page.offset < 500
        }
        var existing = Set(page.playlists.map(\.id))
        let additions = items.filter { existing.insert($0.id).inserted }
        page.playlists += additions
        page.hasMore = page.hasMore && !additions.isEmpty
        return page
    }
}

struct ExploreView: View {
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                categoryChips
                    .padding(.top, 8)

                if !model.matchesCurrentAccount {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if model.selectedCategory == "排行榜" {
                    ToplistGrid(toplists: model.toplists)
                        .padding(.horizontal, Theme.Layout.contentInset)
                    if model.isLoading, model.toplists.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else {
                    CardGrid {
                        ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                            NavigationLink(value: Destination.playlist(playlist.id)) {
                                CoverCardBody(
                                    coverURL: playlist.coverURL?.resizedImageURL(384),
                                    title: playlist.name,
                                    playCount: playlist.playCount
                                ) {
                                    playPlaylist(playlist.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .staggeredAppearance(index: index % 10, id: "explore-\(playlist.id)")
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if model.hasMore, model.error == nil {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadMore() }
                            }
                    }
                }

                if let message = model.error, model.matchesCurrentAccount {
                    ErrorStateView(message: message) { Task { await model.retry() } }
                } else if model.matchesCurrentAccount, !model.isLoading,
                          model.playlists.isEmpty, model.toplists.isEmpty {
                    VStack(spacing: 12) {
                        EmptyStateView(icon: "music.note.list", title: "没有找到相关结果")
                        Button("刷新") { Task { await model.retry() } }
                            .buttonStyle(.bordered)
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("精选")
        .task(id: account.socialSession) { await model.activate() }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Spacer().frame(width: Theme.Layout.contentInset - 8)
                ForEach(ExploreViewModel.categories, id: \.self) { category in
                    Button {
                        model.select(category)
                    } label: {
                        Text(LocalizedStringKey(category))
                    }
                    .buttonStyle(.chip(isSelected: model.selectedCategory == category))
                }
                Spacer().frame(width: Theme.Layout.contentInset - 8)
            }
            .padding(.vertical, 2)
        }
    }

    private func playPlaylist(_ id: Int) {
        Task {
            do { try await PlaylistPlayback.start(id: id) }
            catch { ToastCenter.shared.show(error.localizedDescription) }
        }
    }
}

// MARK: - Toplist grid

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                NavigationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []
    @State private var error: String?
    @State private var isLoading = false
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                if isLoading, toplists.isEmpty { ProgressView().frame(minHeight: 300) }
                if let error {
                    ErrorStateView(message: error) { Task { await load(force: true) } }
                } else if !isLoading, toplists.isEmpty {
                    VStack(spacing: 12) {
                        EmptyStateView(icon: "music.note.list", title: "没有找到相关结果")
                        Button("刷新") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task(id: account.socialSession) { await load() }
    }

    private func load(force: Bool = false) async {
        let binding = DiscoveryCacheContext.current
        isLoading = true
        error = nil
        defer { if binding == .current { isLoading = false } }
        if let cached = await PageDataCache.shared.load([ToplistItem].self, key: DiscoveryCache.toplistsKey, scope: "public") {
            toplists = cached.value
        }
        do {
            let values = try await DiscoveryCache.toplists(context: binding, force: force)
            try binding.validate()
            toplists = values
        } catch is CancellationError {
        } catch {
            if binding == .current { self.error = error.localizedDescription }
        }
    }
}
