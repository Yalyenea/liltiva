import Combine
import SwiftUI

public struct LiltivaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared
    @StateObject private var shortcuts = ShortcutManager.shared

    public init() {}

    public var body: some Scene {
        Window("Liltiva", id: "main") {
            MainWindow()
                .scrollIndicators(.never)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
                .environmentObject(toasts)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
                .frame(minWidth: Theme.Layout.minWindowWidth,
                       minHeight: Theme.Layout.minWindowHeight)
        }
        .defaultSize(width: Theme.Layout.defaultWindowWidth,
                     height: Theme.Layout.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            NavigationCommands()
            CommandMenu("播放") {
                Button(player.isPlaying ? String(localized: "暂停") : String(localized: "播放")) {
                    player.togglePlayPause()
                }
                .disabled(!player.hasCurrentTrack)

                Button("下一首") { player.next() }
                    .keyboardShortcut(shortcuts.shortcut(for: .nextTrack).menuShortcut)
                Button("上一首") { player.previous() }
                    .keyboardShortcut(shortcuts.shortcut(for: .previousTrack).menuShortcut)

                Divider()

                Button("播放模式") { player.cyclePlaybackMode() }
                    .keyboardShortcut(shortcuts.shortcut(for: .cycleRepeatMode).menuShortcut)

                Divider()

                SleepTimerMenu(player: player)

                Divider()
                ForEach([ShortcutAction.seekBackward, .seekForward, .toggleMute, .volumeDown, .volumeUp]) { action in
                    Button(action.displayName) { shortcuts.executeAction(action) }
                        .keyboardShortcut(shortcuts.shortcut(for: action).menuShortcut)
                }

                Divider()

                Button(player.currentTrack.map { AccountStore.shared.isLiked($0.id) ? String(localized: "取消喜欢") : String(localized: "喜欢") } ?? String(localized: "喜欢")) {
                    if let track = player.currentTrack {
                        Task { await account.toggleLike(trackID: track.id) }
                    }
                }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleLike).menuShortcut)
                .disabled(!player.hasCurrentTrack)

                Button("歌词") {
                    player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
                }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleLyrics).menuShortcut)

                Button("播放队列") {
                    player.activePanel = player.activePanel == .queue ? nil : .queue
                }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleQueue).menuShortcut)

                Button("歌曲评论") { shortcuts.executeAction(.toggleComments) }
                    .keyboardShortcut(shortcuts.shortcut(for: .toggleComments).menuShortcut)
                    .disabled(!player.hasCurrentTrack)

                ForEach([ShortcutAction.toggleNowPlaying, .toggleDesktopLyrics]) { action in
                    Button(action.displayName) { shortcuts.executeAction(action) }
                        .keyboardShortcut(shortcuts.shortcut(for: action).menuShortcut)
                }
            }

        }

        Settings {
            SettingsView()
                .scrollIndicators(.never)
                .environment(\.openDestination, { destination in
                    guard destination == .downloaded else { return }
                    NotificationCenter.default.post(name: .showDownloadedMusic, object: nil)
                    _ = AppDelegate.shared?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
                })
                .environmentObject(account)
                .environmentObject(settings)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 650)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var keyMonitor: Any?
    private var appearanceObserver: AnyCancellable?
    /// Installed by the SwiftUI main scene. Calling it recreates the scene
    /// when its NSWindow was released after the user closed the last window.
    var openMainWindow: (() -> Void)?
    /// The single main window, captured by `MainWindowConfigurator`. Its close
    /// interceptor hides (orders out) the window instead of destroying the
    /// single-instance `Window` scene, so we can always bring it back here.
    weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Drive NSApp.appearance from the setting so the NATIVE window chrome
        // (both main and Settings window titlebars/forms) tracks it. SwiftUI's
        // `.preferredColorScheme` alone doesn't reliably revert the native
        // titlebar when switching a fixed theme back to "follow system" (#94).
        applyAppearance(SettingsManager.shared.appearance.colorScheme)
        appearanceObserver = SettingsManager.shared.$appearance
            .map(\.colorScheme)
            .removeDuplicates()
            .sink { [weak self] scheme in self?.applyAppearance(scheme) }
        // App-internal shortcut monitoring (local monitor).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.interceptKeyEvent(event)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerService.shared.checkpointPlayback()
        PlaybackStateStorage.flush()
    }

    @MainActor
    static func restartApplication() async throws {
        PlayerService.shared.checkpointPlayback()
        PlaybackStateStorage.flush()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Keep this instance available if launching the replacement fails.
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    /// Deliver recording input before playback shortcuts or menu key equivalents consume it.
    @MainActor
    static func interceptKeyEvent(_ event: NSEvent) -> NSEvent? {
        if let recorder = event.window?.firstResponder as? ShortcutRecorderView.RecorderNSView {
            recorder.keyDown(with: event)
            return nil
        }
        // The active search owns Escape before playback panels underneath it.
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let editor = event.window?.firstResponder as? NSTextView,
           let field = editor.delegate as? ShortcutSearchField.Field {
            field.exit?()
            return nil
        }
        // Dismiss the topmost playback surface before its underlying page.
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           PlayerService.shared.dismissPlaybackPresentation() {
            return nil
        }
        return ShortcutManager.shared.handleKeyEvent(event) ? nil : event
    }

    private func applyAppearance(_ scheme: ColorScheme?) {
        switch scheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow system
        }
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.shared.makeMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // `hasVisibleWindows` is unreliable here: helper windows such as the
        // desktop-lyrics overlay make it `true` even when the main window is
        // gone, so decide based on the main window itself.
        //
        // `MainWindowConfigurator` keeps the main window alive on close
        // (orders it out rather than destroying the scene), so it is normally
        // still around — just hidden and/or miniaturised, and possibly behind
        // other windows. Restore and front it. Only if it truly no longer
        // exists do we ask SwiftUI to recreate the scene.
        let target = mainWindow ?? sender.windows.first {
            $0.styleMask.contains(.titled) && $0.canBecomeMain
        }
        if let window = target {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // The window is on screen again: let the page's animations resume
            // even if the occlusion observer lags the fronting, and bring the
            // page itself back.
            let onScreen = window.isVisible && !window.isMiniaturized
            MainWindowVisibility.shared.update(isVisible: onScreen, isOnScreen: onScreen)
        } else {
            openMainWindow?()
        }
        // Fully handled above; returning `false` prevents AppKit from also
        // enqueuing another SwiftUI scene request (which re-created #58's
        // duplicate window).
        return false
    }
}
