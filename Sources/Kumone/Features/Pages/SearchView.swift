import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "综合"
        case songs = "单曲"
        case artists = "歌手"
        case albums = "专辑"
        case playlists = "歌单"

        var id: String { rawValue }
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var playlists: [PlaylistSummary] = []
    @Published var isLoading = false
    @Published var loadedTabs: Set<Tab> = []
    @Published var error: String?
    private var context: DiscoveryCacheContext?
    private var generation = 0
    var matchesCurrentAccount: Bool { context == .current }

    init(query: String) {
        self.query = query
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        generation += 1
        loadedTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    func load(tab: Tab, force: Bool = false) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let binding = DiscoveryCacheContext.current
        if context != binding {
            context = binding
            loadedTabs.removeAll()
            songs = []; artists = []; albums = []; playlists = []
        }
        generation += 1
        guard !trimmed.isEmpty else {
            isLoading = false
            error = nil
            return
        }
        let ticket = generation
        let key = SearchResultCache.Key(query: trimmed, tab: tab.rawValue, scope: binding.scope, session: binding.session)
        error = nil
        if !force, let cached = SearchResultCache.shared.value(for: key) {
            apply(cached, tab: tab)
            loadedTabs.insert(tab)
            isLoading = false
            return
        }
        isLoading = true
        defer { if ticket == generation, binding == .current { isLoading = false } }
        do {
            try binding.validate()
            var results = SearchResultCache.Results()
            switch tab {
            case .all:
                async let songsTask = NeteaseAPI.search(trimmed, type: .songs, limit: 12)
                async let artistsTask = NeteaseAPI.search(trimmed, type: .artists, limit: 10)
                async let albumsTask = NeteaseAPI.search(trimmed, type: .albums, limit: 10)
                async let playlistsTask = NeteaseAPI.search(trimmed, type: .playlists, limit: 10)
                let (songs, artists, albums, playlists) = try await (songsTask, artistsTask, albumsTask, playlistsTask)
                results = .init(songs: songs.songs ?? [], artists: artists.artists ?? [],
                                albums: albums.albums ?? [], playlists: playlists.playlists ?? [])
            case .songs:
                results.songs = try await NeteaseAPI.search(trimmed, type: .songs, limit: 100).songs ?? []
            case .artists:
                results.artists = try await NeteaseAPI.search(trimmed, type: .artists, limit: 50).artists ?? []
            case .albums:
                results.albums = try await NeteaseAPI.search(trimmed, type: .albums, limit: 50).albums ?? []
            case .playlists:
                results.playlists = try await NeteaseAPI.search(trimmed, type: .playlists, limit: 50).playlists ?? []
            }
            try binding.validate()
            guard ticket == generation, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            SearchResultCache.shared.insert(results, for: key)
            apply(results, tab: tab)
            loadedTabs.insert(tab)
        } catch is CancellationError {
        } catch {
            guard ticket == generation, binding == .current else { return }
            loadedTabs.remove(tab)
            self.error = error.localizedDescription
        }
    }

    private func apply(_ results: SearchResultCache.Results, tab: Tab) {
        switch tab {
        case .all:
            songs = results.songs; artists = results.artists; albums = results.albums; playlists = results.playlists
        case .songs: songs = results.songs
        case .artists: artists = results.artists
        case .albums: albums = results.albums
        case .playlists: playlists = results.playlists
        }
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @State private var searchText: String = ""
    @EnvironmentObject private var account: AccountStore

    init(query: String) {
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        searchContent
        .navigationTitle(searchText.isEmpty ? "搜索" : String(localized: "搜索：\(searchText)"))
        .task(id: "\(model.tab.rawValue):\(account.socialSession ?? "guest")") {
            await model.load(tab: model.tab)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if !model.matchesCurrentAccount {
            ProgressView().frame(maxWidth: .infinity, minHeight: 300)
        } else if model.tab == .songs, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            TrackListScrollView(trackIDs: model.songs.map(\.id)) {
                VStack(spacing: 20) {
                    tabPicker
                    if model.isLoading && currentEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                    retryError
                }
            } rows: { layout in
                TrackListView(tracks: model.songs, layout: layout)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            } footer: {
                PlayerClearanceSpacer()
            }
        } else {
            mixedResults.clipped()
        }
    }

    private var mixedResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    tabPicker
                    retryError

                    if model.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                }
                PlayerClearanceSpacer()
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $model.tab) {
            ForEach(SearchViewModel.Tab.allCases) { tab in
                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var retryError: some View {
        if let message = model.error {
            ErrorStateView(message: message) {
                Task { await model.load(tab: model.tab, force: true) }
            }
        }
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty && model.albums.isEmpty && model.playlists.isEmpty
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty
        case .albums: return model.albums.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") {
                        model.tab = .songs
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading, model.error == nil {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(tracks: model.songs)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(model.artists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                ArtistDetailView(artistID: artist.id)
            } label: {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                AlbumDetailView(albumID: album.id)
            } label: {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                PlaylistDetailView(playlistID: playlist.id)
            } label: {
                CoverCardBody(
                    coverURL: playlist.coverURL?.resizedImageURL(384),
                    title: playlist.name,
                    playCount: playlist.playCount
                )
            }
            .buttonStyle(.plain)
        }
    }
}
