import SwiftUI

struct MainWindow: View {
    private let externalPath: Binding<[Destination]>?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var toasts: ToastCenter

    /// Whether the main window is on screen at all — the page is put away
    /// while it is not (miniaturised or hidden), see the overlay below.
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @StateObject private var nowPlayingIdle = NowPlayingIdleController()
    @State private var history: NavigationHistory
    @State private var showLogin = false
    @State private var mainColumnGeometry = MainColumnGeometry()
    @State private var nowPlayingChromeHidden = false
    @State private var nowPlayingChromeFadedOut = false
    @State private var nowPlayingChromeTask: Task<Void, Never>?

    init(path: Binding<[Destination]>? = nil) {
        externalPath = path
        _history = State(initialValue: NavigationHistory(path: path?.wrappedValue ?? []))
    }

    private var selection: RootPage {
        get { history.current.page }
        nonmutating set { visit(.init(page: newValue)) }
    }

    private var selectionBinding: Binding<RootPage> {
        Binding(get: { selection }, set: { selection = $0 })
    }

    private var path: [Destination] {
        get { history.current.path }
        nonmutating set { visit(.init(page: selection, path: newValue)) }
    }

    private var pathBinding: Binding<[Destination]> {
        Binding(get: { path }, set: { path = $0 })
    }

    private func visit(_ route: NavigationHistory.Route) {
        history.visit(route)
        externalPath?.wrappedValue = route.path
    }

    private var navigationActions: NavigationActions {
        NavigationActions(canGoBack: history.canGoBack, canGoForward: history.canGoForward,
            back: { navigateHistory(forward: false) }, forward: { navigateHistory(forward: true) },
            canSearchPlaylist: canSearchPlaylist)
    }

    private var canSearchPlaylist: Bool {
        guard !player.showNowPlaying else { return false }
        if let destination = path.last {
            switch destination {
            case .playlist, .radarPlaylist: return true
            default: return false
            }
        }
        return selection == .likedSongs && account.likedSongsPlaylist != nil
    }

    private func navigateHistory(forward: Bool) {
        if forward { history.goForward() } else { history.goBack() }
        externalPath?.wrappedValue = history.current.path
        player.showNowPlaying = false
    }

    var body: some View {
        detailStack
            .environment(\.cachedImageScope, .browsing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: MainColumnGeometry.Layout.self) { proxy in
                MainColumnGeometry.Layout(frame: proxy.frame(in: .named("mainWindow")))
            } action: { layout in
                mainColumnGeometry.update(layout)
            }
        // The page underneath must not show through the playback window's glass.
        .opacity(hasTransparentPlayback ? 0 : 1)
        .allowsHitTesting(!hasTransparentPlayback)
        .accessibilityHidden(hasTransparentPlayback)
        .background(hasTransparentPlayback ? Color.clear : Platform.windowBackgroundColor)
        .containerBackground(
            hasTransparentPlayback
                ? Color.clear : Platform.windowBackgroundColor,
            for: .window
        )
        .coordinateSpace(name: "mainWindow")
        .overlay(alignment: .trailing) {
            if settings.showMainWindowAmbientBackground, !hasTransparentPlayback {
                MainColumnAmbientOverlay(
                    geometry: mainColumnGeometry,
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
            }
        }
        .toolbar {
            // Keep the compact titlebar's height stable in both playback views.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 1)
                }
                // A transparent item still gets a glass border on macOS 26.
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
        .toolbar(removing: .title)
        // Immersive now-playing page: its real toolbar items (navigation,
        // account, search field) step aside, and a placeholder keeps the
        // NSToolbar — and the titlebar height that positions the window
        // buttons at the home position — alive (#128). Only full screen drops
        // the toolbar itself, where the system would otherwise pin it over the
        // page. Keep the single main window alive on Cmd+W / red button so the
        // Dock icon can always bring it back (#60/#63/#66/#70).
        .background(
            MainWindowConfigurator(
                geometry: mainColumnGeometry,
                titlebarContent: AnyView(
                    MainWindowHeader(selection: selectionBinding, showLogin: $showLogin,
                                     path: pathBinding, navigation: navigationActions)
                        .environmentObject(account)
                        .environmentObject(settings)
                ),
                ambientConfiguration: MainWindowAmbientConfiguration(
                    showsAmbientBackground: settings.showMainWindowAmbientBackground && !hasTransparentPlayback,
                    showsTitlebarAmbientBackground: !nowPlayingChromeHidden,
                    showsNowPlaying: player.showNowPlaying,
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity,
                    isDark: isDarkAppearance
                ),
                titlebarFadedOut: nowPlayingChromeFadedOut,
                toolbarHidden: nowPlayingChromeHidden
            )
        )
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }))
        .modifier(MeteredDownloadAlert())
        .modifier(PlaybackLifecycle())
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadedMusic)) { _ in
            player.showNowPlaying = false
            selection = .downloaded
            path = []
        }
        .environmentObject(artworkStore)
        .task {
            // Keep this action in the app delegate: when the user closes the
            // last WindowGroup window, there is no view left to receive a
            // Dock reopen event directly.
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
            await DownloadManager.shared.start()
            if KumonePaths.isOfflineUITest { selection = .downloaded }
            await account.bootstrap()
        }
        .onChange(of: settings.showDesktopLyrics) { _ in
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
        }
        .onChange(of: settings.showMainWindowAmbientBackground) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        // Warm the cover as soon as a track loads: the now-playing page only
        // slides in smoothly when the artwork is already in memory.
        .onChange(of: player.hasCurrentTrack) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        .onChange(of: player.showNowPlaying) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            nowPlayingChromeTask?.cancel()
            if player.showNowPlaying {
                // Quiet the titlebar as the page rises to cover it: hide the
                // title text, then swap the toolbar's items (search field,
                // navigation) for a placeholder once nothing is left to
                // see — snapping them away at once reads as a glitch above
                // the rising page. The buttons stay: this page is the whole
                // window, so they are its only way to close, dock or zoom it
                // (#128).
                nowPlayingChromeTask = Task { @MainActor in
                    await ImageCache.shared.trimMemory()
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    nowPlayingChromeFadedOut = true
                    try? await Task.sleep(for: .milliseconds(230))
                    guard !Task.isCancelled else { return }
                    nowPlayingChromeHidden = true
                    // Keep the underlying page for the slide, then release
                    // its native row hosts and decoded browsing covers together.
                    windowVisibility.setBrowsingVisible(false)
                }
            } else {
                windowVisibility.setBrowsingVisible(true)
                nowPlayingChromeHidden = false
                nowPlayingChromeFadedOut = false
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet()
                .noFocusRing()
        }
        .overlay {
            // The page is put away while the window is off screen
            // (miniaturised or ordered out): the vinyl, lyrics and cover it
            // holds together add up to tens of megabytes, and rebuilding the
            // page takes a single frame when the window comes back. The
            // player state — and the page on restore — is untouched.
            if player.showNowPlaying, windowVisibility.isOnScreen {
                NowPlayingView(onOpenDestination: openDestination)
                    .environmentObject(artworkStore)
                    .background(ArrowCursorOverride())
                    // Resolve the slide at the page boundary, including artwork
                    // inserted asynchronously while the transition is running.
                    .geometryGroup()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // One persistent transport sits above both page surfaces, so opening
        // Now Playing never duplicates controls or hides its queue panel.
        .playerChrome()
        .background(NowPlayingActivityMonitor(
            controller: nowPlayingIdle,
            isEnabled: player.showNowPlaying && windowVisibility.isOnScreen
                && !nowPlayingIdle.isShowingOptions
                && player.activePanel == nil
        ))
        .environmentObject(nowPlayingIdle)
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
        .focusedSceneValue(\.navigationActions, navigationActions)
        .onChange(of: externalPath?.wrappedValue) { _, value in
            if let value { path = value }
        }
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .hiddenDuringCleanPlayback(nowPlayingIdle.isClean)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
            }
        }
        .animation(AppAnimation.smooth, value: player.showNowPlaying)
        .animation(.spring(duration: 0.3), value: toasts.current)
        .noFocusRing()
    }

    private var detailStack: some View {
        NavigationStack(path: pathBinding) {
            rootView
                .playerContentInset()
                .appDestinations()
                .toolbar(removing: .title)
                .navigationBarBackButtonHidden(true)
        }
        .onChange(of: history.current) { _ in
            AppDelegate.shared?.mainWindow?.clearAutoFocusIfNeeded()
        }
    }

    private func openDestination(_ destination: Destination) {
        guard player.showNowPlaying else {
            path.appendIfNotCurrent(destination)
            return
        }

        withAnimation(AppAnimation.smooth, completionCriteria: .removed) {
            player.showNowPlaying = false
        } completion: {
            path.appendIfNotCurrent(destination)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch selection {
        case .profile:
            if let uid = account.authenticatedAccountID { ProfileView(userID: uid).id(uid) }
            else { loginPrompt("登录后查看个人主页与消息") }
        case .messages:
            MessagesView()
        case .downloaded:
            DownloadedMusicView()
        case .home:
            HomeView()
        case .explore:
            ExploreView()
        case .fm:
            FMView()
        case .likedSongs:
            if let playlist = account.likedSongsPlaylist {
                PlaylistDetailView(playlistID: playlist.id, isLikedList: true)
                    .id(playlist.id)
            } else {
                loginPrompt("登录后查看你喜欢的音乐")
            }
        case .daily:
            DailySongsView()
        case .created:
            if account.hasAuthCookie {
                CreatedPlaylistsView()
            } else {
                loginPrompt("登录后查看你创建的歌单")
            }
        case .recents:
            RecentsView()
        case .collections:
            if account.hasAuthCookie {
                CollectionsView()
            } else {
                loginPrompt("登录后查看你的收藏")
            }
        case .cloud:
            CloudView()
        }
    }

    private func loginPrompt(_ message: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.headline)
            Button("登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsCurrentArtwork: Bool {
        settings.showMainWindowAmbientBackground || player.hasCurrentTrack
    }

    private var hasTransparentPlayback: Bool {
        player.showNowPlaying && settings.transparentPlayback
    }

    private var isDarkAppearance: Bool {
        (settings.appearance.colorScheme ?? colorScheme) == .dark
    }
}

// MARK: - Cursor override

/// Claims the arrow cursor over the whole now-playing page. AppKit cursor
/// rects ignore hit-testing, so without this the split-view divider's resize
/// cursor leaks through the full-window overlay wherever the divider sits (#6).
struct ArrowCursorOverride: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorOverrideView { CursorOverrideView() }

    func updateNSView(_ nsView: CursorOverrideView, context: Context) {}

    final class CursorOverrideView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying the single-instance `Window` scene. Destroying the scene left
/// the app running with no way to reopen it (#60/#66/#70); hiding keeps the
/// SwiftUI scene fully alive so `AppDelegate.applicationShouldHandleReopen`
/// can front it again on a Dock click. Every other window-delegate callback is
/// forwarded untouched to SwiftUI's own delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    @ObservedObject var geometry: MainColumnGeometry
    let titlebarContent: AnyView
    let ambientConfiguration: MainWindowAmbientConfiguration
    /// Hides the titlebar text while the immersive page covers the window;
    /// the window buttons stay on top of the page (#128).
    let titlebarFadedOut: Bool
    /// Drops the window toolbar while the immersive page covers the window in
    /// full screen, where the system otherwise pins it over the page. In a
    /// window the toolbar stays (its items swapped for a placeholder) so the
    /// titlebar keeps the height that positions the window buttons (#128).
    let toolbarHidden: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let configuration = resolvedAmbientConfiguration
        DispatchQueue.main.async {
            context.coordinator.setTitlebarContent(titlebarContent)
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: view,
                ambientConfiguration: configuration
            )
            context.coordinator.setTitlebarFadedOut(titlebarFadedOut)
            context.coordinator.setToolbarHidden(toolbarHidden)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let configuration = resolvedAmbientConfiguration
        DispatchQueue.main.async {
            context.coordinator.setTitlebarContent(titlebarContent)
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: nsView,
                ambientConfiguration: configuration
            )
            context.coordinator.setTitlebarFadedOut(titlebarFadedOut)
            context.coordinator.setToolbarHidden(toolbarHidden)
        }
    }

    private var resolvedAmbientConfiguration: MainWindowAmbientConfiguration {
        var configuration = ambientConfiguration
        configuration.mainColumnLeadingInset = geometry.layout.leadingInset
        return configuration
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private let ambientAppearance = MainWindowAmbientAppearanceController()
        private let titlebar = MainWindowTitlebar()
        private var titlebarContent = AnyView(EmptyView())
        private weak var configurationHost: NSView?
        private var pendingAmbientConfiguration: MainWindowAmbientConfiguration?
        private var hasScheduledAmbientConfiguration = false
        private var titlebarFadedOut = false
        private var windowToolbarHidden = false
        private var visibilityObservers: [NSObjectProtocol] = []

        deinit {
            visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }
        /// The item views the immersive page swaps out, kept so the home page
        /// gets them back; see `suppressImmersiveToolbarItems`.
        private var hiddenToolbarItemViews: [String: NSView] = [:]
        /// Separator items the page hides (they have no view to swap).
        private var hiddenToolbarSeparatorIdentifiers: Set<String> = []

        func setTitlebarContent(_ content: AnyView) {
            titlebarContent = content
            if let window {
                titlebar.update(content: content, in: window)
            }
        }

        /// Hides the titlebar text while the immersive page covers the window.
        /// The toolbar is dropped separately, and the window buttons stay: this
        /// page is the whole window, so they are its only way to close,
        /// minimize or zoom it — and the page paints its backdrop around them
        /// (#128). Leaving them in the system's hands also keeps their
        /// full-screen behaviour (auto-hide, reveal on hover) for free.
        func setTitlebarFadedOut(_ fadedOut: Bool) {
            guard fadedOut != titlebarFadedOut else { return }
            titlebarFadedOut = fadedOut
            titlebar.setFadedOut(fadedOut)
            window?.titleVisibility = .hidden
            ambientAppearance.setTitlebarMaskFadedOut(fadedOut)
        }

        /// Drops the window toolbar while the immersive page is up *in full
        /// screen*, the classic AppKit way: `toolbar.isVisible = false` takes
        /// the bar away and leaves the window buttons in place. In a window
        /// the toolbar stays: the page swaps its items for a placeholder (see
        /// MainWindow) so the titlebar keeps the height that parks the buttons
        /// at their home position (#128). Hiding it through SwiftUI's
        /// `.toolbar(.hidden, for: .windowToolbar)` instead takes the entire
        /// titlebar — buttons included — down with it, and leaves AppKit's
        /// `isVisible` at `true`, which is what pins a toolbar over the page
        /// in full screen.
        func setToolbarHidden(_ hidden: Bool) {
            guard hidden != windowToolbarHidden else { return }
            windowToolbarHidden = hidden
            applyWindowToolbarVisibility()
        }

        /// SwiftUI re-commits toolbar visibility on its own schedule and can
        /// bring the toolbar back mid-immersion, so re-apply whenever the
        /// window state may have moved underneath us. Only full screen hides
        /// the toolbar; in a window it must stay so the window buttons hold
        /// the home position (#128).
        private func applyWindowToolbarVisibility() {
            guard let window, let toolbar = window.toolbar else { return }
            let shouldBeVisible = !(windowToolbarHidden
                && window.styleMask.contains(.fullScreen))
            if toolbar.isVisible != shouldBeVisible {
                toolbar.isVisible = shouldBeVisible
            }
            suppressImmersiveToolbarItems(in: toolbar)
        }

        /// Takes the whole toolbar's items out of the immersive page — except
        /// the 1pt placeholder keeping the bar (and the titlebar height that
        /// parks the window buttons) alive. The split view's sidebar toggle
        /// and separator, and the navigation stack's back button when the page
        /// was opened from a pushed screen, are all built into the toolbar
        /// whether or not the page covers them; `.toolbar(removing:)` is a
        /// no-op for what the frameworks inject. Merely hiding an item's view
        /// is not enough either: AppKit re-shows toolbar item views on its own
        /// schedule, so hovering brings a button right back, live and
        /// clickable, over the page. Swapping in an empty stand-in instead
        /// leaves nothing to re-show, whatever the toolbar decides; separator
        /// items have no view to swap, so those are hidden outright.
        private func suppressImmersiveToolbarItems(in toolbar: NSToolbar) {
            if windowToolbarHidden {
                for item in toolbar.items {
                    if let view = item.view {
                        guard !(view is HiddenToolbarItemView) else { continue }
                        hiddenToolbarItemViews[item.itemIdentifier.rawValue] = view
                        // One stand-in per item: a view has a single
                        // superview, so a shared one would hop between items.
                        item.view = HiddenToolbarItemView()
                    } else if item.itemIdentifier.rawValue.lowercased().contains("separator"),
                              !item.isHidden {
                        hiddenToolbarSeparatorIdentifiers.insert(item.itemIdentifier.rawValue)
                        item.isHidden = true
                    }
                }
            } else {
                for (identifier, original) in hiddenToolbarItemViews {
                    hiddenToolbarItemViews.removeValue(forKey: identifier)
                    guard let item = toolbar.items.first(where: {
                        $0.itemIdentifier.rawValue == identifier
                    }),
                    item.view is HiddenToolbarItemView else { continue }
                    item.view = original
                }
                for identifier in hiddenToolbarSeparatorIdentifiers {
                    hiddenToolbarSeparatorIdentifiers.remove(identifier)
                    toolbar.items.first {
                        $0.itemIdentifier.rawValue == identifier
                    }?.isHidden = false
                }
            }
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            titlebar.update(content: titlebarContent, in: window)
            titlebar.setFadedOut(titlebarFadedOut)
            window.isReleasedWhenClosed = false
            // Insert ourselves as the delegate, forwarding to whatever
            // delegate SwiftUI installed.
            if window.delegate !== self {
                forwardee = window.delegate
                window.delegate = self
            }
            AppDelegate.shared?.mainWindow = window
            window.clearAutoFocusIfNeeded()
            observeFullScreenChanges(of: window)
            observeWindowVisibility(of: window)
            refreshWindowVisibility()
        }

        /// Full screen hands the titlebar and toolbar to a system-managed
        /// window of their own, and the hand-off re-commits toolbar
        /// visibility: the toolbar can come back pinned over the immersive
        /// page, covering the page's controls and swallowing their clicks —
        /// the collapse chevron then only answers to Escape (#128). Re-assert
        /// the immersive state once the transition settles.
        private func observeFullScreenChanges(of window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.reassertChromeState()
                        // SwiftUI re-commits toolbar visibility around the
                        // hand-off (see MainWindowAmbientAppearanceController),
                        // so run one more pass once that commit settles.
                        try? await Task.sleep(for: .milliseconds(100))
                        self?.reassertChromeState()
                    }
                }
            }
        }

        /// SwiftUI keeps the page's `TimelineView`s ticking while the window
        /// is off screen, so track the states that take it there — and bring
        /// it back — and tell `MainWindowVisibility`.
        private func observeWindowVisibility(of window: NSWindow) {
            let center = NotificationCenter.default
            visibilityObservers.forEach { center.removeObserver($0) }
            visibilityObservers.removeAll()
            for name in [
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ] {
                visibilityObservers.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshWindowVisibility()
                    }
                })
            }
            // Hiding the application need not change NSWindow.isVisible.
            // Observe the app lifecycle as well so Cmd-H releases the page.
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                visibilityObservers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshWindowVisibility() }
                })
            }
        }

        /// Miniaturised, ordered out and fully occluded all mean nothing can
        /// see the page: its animations stand their clocks down, and a window
        /// in the Dock (or hidden) also has the page itself put away
        /// (#128 performance work).
        private func refreshWindowVisibility() {
            guard let window else { return }
            let onScreen = window.isVisible && !window.isMiniaturized && !NSApp.isHidden
            MainWindowVisibility.shared.update(
                isVisible: onScreen && window.occlusionState.contains(.visible),
                isOnScreen: onScreen
            )
        }

        private func reassertChromeState() {
            window?.titleVisibility = .hidden
            applyWindowToolbarVisibility()
            refreshWindowVisibility()
        }

        func requestAmbientBackgroundConfiguration(
            from host: NSView,
            ambientConfiguration: MainWindowAmbientConfiguration
        ) {
            configurationHost = host
            pendingAmbientConfiguration = ambientConfiguration
            guard !hasScheduledAmbientConfiguration else { return }
            hasScheduledAmbientConfiguration = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledAmbientConfiguration = false
                guard let configuration = self.pendingAmbientConfiguration else { return }
                self.pendingAmbientConfiguration = nil
                self.attach(to: self.configurationHost?.window)
                guard let window = self.window else { return }
                self.ambientAppearance.configure(configuration, in: window)
                // SwiftUI re-commits toolbar visibility on its own schedule;
                // put the immersive state back whenever it may have drifted.
                self.applyWindowToolbarVisibility()
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
                titlebar.updateLayout(in: window)
                window.contentView?.disableFocusRingsRecursively()
            }
            refreshWindowVisibility()
        }

        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
                titlebar.updateLayout(in: window)
            }
            refreshWindowVisibility()
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            refreshWindowVisibility()
            return false
        }

        // Transparently forward every other delegate callback to SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true { return forwardee }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

/// Stands in for a toolbar item the immersive page does not want shown: it
/// draws nothing, takes no hits, and — unlike a merely hidden view, which the
/// toolbar may re-show on hover — has nothing to show.
private final class HiddenToolbarItemView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .panelSurface(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
