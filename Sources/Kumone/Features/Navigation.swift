import SwiftUI

extension Notification.Name {
    static let showDownloadedMusic = Notification.Name("Kumone.showDownloadedMusic")
}

private struct OpenLoginKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (Destination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLogin: () -> Void {
        get { self[OpenLoginKey.self] }
        set { self[OpenLoginKey.self] = newValue }
    }

    var openDestination: (Destination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

struct PlayerChromeModifier: ViewModifier {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var nowPlayingIdle: NowPlayingIdleController
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var swipePresentation = TrackSwipePresentation()
    @State private var showsVolume = false
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    rightPanel.hiddenDuringCleanPlayback(nowPlayingIdle.isClean)
                }
            PlayerBar(showsVolume: $showsVolume)
                .environment(\.colorScheme, player.showNowPlaying ? .dark : colorScheme)
                .hiddenDuringCleanPlayback(nowPlayingIdle.isClean && !nowPlayingIdle.isPreviewingTransport)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsVolume {
                // Keep the slider inside the window's hit region, above the bar.
                ZStack(alignment: .bottomTrailing) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { showsVolume = false }
                        .accessibilityHidden(true)
                    VolumeControl(isExpanded: true, showsVolume: $showsVolume)
                        .environment(\.colorScheme, player.showNowPlaying ? .dark : colorScheme)
                        .padding(.trailing, 12)
                        .padding(.bottom, (Theme.Layout.playerBarHeight - 32) / 2)
                }
                .hiddenDuringCleanPlayback(nowPlayingIdle.isClean && !nowPlayingIdle.isPreviewingTransport)
            }
        }
        .environmentObject(swipePresentation)
        .onChange(of: player.currentTrack?.id) { _, _ in
            swipePresentation.trackDidChange()
        }
        .onDisappear { swipePresentation.reset() }
        .animation(AppAnimation.standard, value: player.activePanel)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let panel = player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel()
                case .queue:
                    QueuePanel()
                case .comments:
                    if let track = player.currentTrack {
                        // Each song owns its request state and draft, including late replies.
                        CommentsPanel(track: track).id(track.id)
                    }
                }
            }
            .environment(\.colorScheme, player.showNowPlaying ? .dark : colorScheme)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .padding(.trailing, 16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

enum RootPage: String, Identifiable {
    case downloaded
    case home
    case explore
    case fm
    case likedSongs
    case daily
    case created
    case recents
    case collections
    case cloud
    case profile, messages

    var id: String { rawValue }

    static let primaryPages: [RootPage] = [.home, .likedSongs, .daily, .created]
    static let menuPages: [RootPage] = [.profile, .messages, .explore, .fm, .downloaded, .recents, .collections, .cloud]
    static let navigationPages = primaryPages + menuPages

    var requiresLogin: Bool {
        switch self {
        case .home, .explore, .fm, .downloaded: return false
        default: return true
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "推荐"
        case .likedSongs: return "我喜欢"
        case .daily: return "日推"
        case .created: return "我的歌单"
        case .explore: return "精选"
        case .fm: return "漫游"
        case .downloaded: return "已下载"
        case .recents: return "最近播放"
        case .collections: return "我的收藏"
        case .cloud: return "音乐云盘"
        case .profile: return "个人主页"
        case .messages: return "消息中心"
        }
    }

    /// Keep compact tab labels separate from full page names and tooltips.
    var tabTitle: LocalizedStringKey {
        switch self {
        case .likedSongs: return "navigation.tab.liked"
        case .created: return "navigation.tab.created"
        case .downloaded: return "navigation.tab.downloaded"
        case .recents: return "navigation.tab.recents"
        case .collections: return "navigation.tab.collections"
        case .cloud: return "navigation.tab.cloud"
        case .profile: return "navigation.tab.profile"
        case .messages: return "navigation.tab.messages"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .likedSongs: return "heart"
        case .daily: return "calendar"
        case .created: return "music.note.list"
        case .explore: return "square.grid.2x2"
        case .fm: return "wave.3.right.circle"
        case .downloaded: return "arrow.down.circle"
        case .recents: return "clock"
        case .collections: return "star"
        case .cloud: return "icloud"
        case .profile: return "person.crop.circle"
        case .messages: return "bell"
        }
    }

    func togglePin(in pages: inout [RootPage]) {
        if let index = pages.firstIndex(of: self) {
            pages.remove(at: index)
        } else {
            pages.append(self)
        }
    }

    static func restoredPinnedPages(_ rawValues: [String]) -> [RootPage] {
        var pages: [RootPage] = []
        for rawValue in rawValues {
            // Merge the retired saved-playlist tab without losing its position
            // or producing a second Collections tab when both were pinned.
            let migrated = rawValue == "saved" ? "collections" : rawValue
            guard let page = RootPage(rawValue: migrated),
                  !pages.contains(page) else { continue }
            pages.append(page)
        }
        return pages
    }

    static func loadPinnedPages(from defaults: UserDefaults) -> [RootPage] {
        if let stored = defaults.stringArray(forKey: SettingsManager.Keys.visibleNavigationPages) {
            // An empty list is intentional: the More menu can restore every tab.
            return restoredPinnedPages(stored)
        }
        // Older versions stored only optional pins; carry over the full visible bar once.
        let legacyPins = defaults.stringArray(forKey: SettingsManager.Keys.pinnedNavigationPages) ?? []
        return restoredPinnedPages(primaryPages.map(\.rawValue) + legacyPins)
    }
}

enum Destination: Hashable {
    case profile(Int)
    case people(Int, followers: Bool)
    case messages
    case conversation(Int, String)
    case downloaded, downloadTasks
    case playlist(Int)
    case radarPlaylist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case toplists
    case recents
    case collections
    case cloud
    case search(String)
}

extension Array where Element == Destination {
    mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}

/// Record complete routes so history also crosses root tabs and restores
/// their destination stacks, rather than only remembering the last pushed page.
struct NavigationHistory {
    struct Route: Equatable {
        var page: RootPage = .home
        var path: [Destination] = []
    }

    private(set) var current: Route
    private var previous: [Route] = []
    private var next: [Route] = []
    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !next.isEmpty }

    init(path: [Destination] = []) { current = Route(path: path) }

    mutating func visit(_ route: Route) {
        guard route != current else { return }
        previous.append(current)
        current = route
        next.removeAll()
    }

    mutating func goBack() {
        guard let route = previous.popLast() else { return }
        next.append(current)
        current = route
    }

    mutating func goForward() {
        guard let route = next.popLast() else { return }
        previous.append(current)
        current = route
    }
}

struct NavigationActions {
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void
    var canSearchPlaylist = false
}

private struct NavigationActionsKey: FocusedValueKey {
    typealias Value = NavigationActions
}

extension FocusedValues {
    var navigationActions: NavigationActions? {
        get { self[NavigationActionsKey.self] }
        set { self[NavigationActionsKey.self] = newValue }
    }
}

struct NavigationCommands: Commands {
    @FocusedValue(\.navigationActions) private var actions
    @ObservedObject private var shortcuts = ShortcutManager.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("后退") { actions?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.canGoBack != true)
            Button("前进") { actions?.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.canGoForward != true)
            Divider()
            Button("全局搜索") { shortcuts.executeAction(.searchLibrary) }
                .keyboardShortcut(shortcuts.shortcut(for: .searchLibrary).menuShortcut)
                .disabled(actions == nil)
            Button("搜索歌单内歌曲") { shortcuts.executeAction(.searchPlaylist) }
                .keyboardShortcut(shortcuts.shortcut(for: .searchPlaylist).menuShortcut)
                .disabled(actions?.canSearchPlaylist != true)
            Divider()
            ForEach([ShortcutAction.selectPreviousRow, .selectNextRow, .playSelectedRow]) { action in
                Button(action.displayName) { shortcuts.executeAction(action) }
                    .keyboardShortcut(shortcuts.shortcut(for: action).menuShortcut)
                    .disabled(actions == nil)
            }
        }
    }
}

/// Registers all shared navigation destinations on a stack.
struct DestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { destination in
            Group {
                switch destination {
                case .profile(let uid):
                    ProfileView(userID: uid)
                case .people(let uid, let followers):
                    SocialPeopleView(userID: uid, followers: followers)
                case .messages:
                    MessagesView()
                case .conversation(let uid, let name):
                    ConversationView(userID: uid, name: name)
                case .downloaded:
                    DownloadedMusicView()
                case .downloadTasks:
                    DownloadTasksView()
                case .playlist(let id):
                    PlaylistDetailView(playlistID: id)
                case .radarPlaylist(let id):
                    PlaylistDetailView(playlistID: id, recommendationContext: .radar)
                case .album(let id):
                    AlbumDetailView(albumID: id)
                case .artist(let id):
                    ArtistDetailView(artistID: id)
                case .daily:
                    DailySongsView()
                case .toplists:
                    ToplistsView()
                case .recents:
                    RecentsView()
                case .collections:
                    CollectionsView()
                case .cloud:
                    CloudView()
                case .search(let query):
                    SearchView(query: query)
                }
            }
            .playerContentInset()
            // Navigation retains the previous page underneath transparent
            // destinations. Cover the full viewport, including loading states.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Platform.windowBackgroundColor)
            .toolbar(removing: .title)
            .navigationBarBackButtonHidden(true)
        }
    }
}

extension View {
    func playerChrome() -> some View {
        modifier(PlayerChromeModifier())
    }

    /// The player is outside navigation, so every destination keeps its full viewport.
    func playerContentInset() -> some View {
        self
    }

    func appDestinations() -> some View {
        modifier(DestinationsModifier())
    }
}

/// A small breathing margin at the end of scrollable content.
struct PlayerClearanceSpacer: View {
    var body: some View {
        Color.clear.frame(
            height: Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin
        )
    }
}
