import SwiftUI
import AppKit
import OSLog

public struct UserShortcut: Codable, Equatable {
    static let unassigned = UserShortcut(key: "", modifiers: [])
    public var key: String
    public var modifiers: ShortcutModifiers

    var normalized: UserShortcut {
        UserShortcut(key: key.lowercased(), modifiers: modifiers)
    }

    public struct ShortcutModifiers: OptionSet, Codable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = ShortcutModifiers(rawValue: 1 << 0)
        public static let shift   = ShortcutModifiers(rawValue: 1 << 1)
        public static let option  = ShortcutModifiers(rawValue: 1 << 2)
        public static let control = ShortcutModifiers(rawValue: 1 << 3)

        public var eventModifiers: EventModifiers {
            var flags: EventModifiers = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }

        public var nsModifierFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }

        public init(nsFlags: NSEvent.ModifierFlags) {
            var flags: ShortcutModifiers = []
            if nsFlags.contains(.command) { flags.insert(.command) }
            if nsFlags.contains(.shift) { flags.insert(.shift) }
            if nsFlags.contains(.option) { flags.insert(.option) }
            if nsFlags.contains(.control) { flags.insert(.control) }
            self = flags
        }
    }

    public var keyboardShortcut: KeyboardShortcut? {
        guard !key.isEmpty else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: modifiers.eventModifiers)
    }

    var menuShortcut: KeyboardShortcut? {
        // Bare menu equivalents also fire in text fields, bypassing our input guard.
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        return keyboardShortcut
    }

    public var displayString: String {
        if key.isEmpty { return String(localized: "无") }
        var str = ""
        if modifiers.contains(.control) { str += "⌃" }
        if modifiers.contains(.option) { str += "⌥" }
        if modifiers.contains(.shift) { str += "⇧" }
        if modifiers.contains(.command) { str += "⌘" }

        switch key {
        case " ": str += "Space"
        case "\u{F703}": str += "→"
        case "\u{F702}": str += "←"
        case "\u{F700}": str += "↑"
        case "\u{F701}": str += "↓"
        case "\u{1B}": str += "⎋"
        case "\u{F704}": str += "F1"
        case "\u{F705}": str += "F2"
        case "\u{F706}": str += "F3"
        case "\u{F707}": str += "F4"
        case "\u{F708}": str += "F5"
        case "\u{F709}": str += "F6"
        case "\u{F70A}": str += "F7"
        case "\u{F70B}": str += "F8"
        case "\u{F70C}": str += "F9"
        case "\u{F70D}": str += "F10"
        case "\u{F70E}": str += "F11"
        case "\u{F70F}": str += "F12"
        case "\r": str += "↩"
        case "\u{7F}": str += "⌫"
        default: str += key.uppercased()
        }
        return str
    }
}

public enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case togglePlayPause
    case nextTrack
    case previousTrack
    case cycleRepeatMode
    case toggleLike
    case toggleLyrics
    case toggleQueue
    case toggleComments
    case closeImmersive
    case volumeUp
    case volumeDown
    case searchPlaylist, searchLibrary
    case toggleNowPlaying, toggleMute, seekBackward, seekForward, toggleDesktopLyrics
    case selectPreviousRow, selectNextRow, playSelectedRow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .togglePlayPause: return String(localized: "播放 / 暂停")
        case .nextTrack: return String(localized: "下一首")
        case .previousTrack: return String(localized: "上一首")
        case .cycleRepeatMode: return String(localized: "播放模式")
        case .toggleLike: return String(localized: "喜欢")
        case .toggleLyrics: return String(localized: "歌词")
        case .toggleQueue: return String(localized: "播放队列")
        case .toggleComments: return String(localized: "歌曲评论")
        case .closeImmersive: return String(localized: "关闭面板 / 播放页")
        case .volumeUp: return String(localized: "增加音量")
        case .volumeDown: return String(localized: "减少音量")
        case .searchPlaylist: return String(localized: "搜索歌单内歌曲")
        case .searchLibrary: return String(localized: "全局搜索")
        case .toggleNowPlaying: return String(localized: "打开 / 收起播放页")
        case .toggleMute: return String(localized: "静音 / 恢复音量")
        case .seekBackward: return String(localized: "后退 5 秒")
        case .seekForward: return String(localized: "前进 5 秒")
        case .toggleDesktopLyrics: return String(localized: "桌面歌词")
        case .selectPreviousRow: return String(localized: "选择上一首歌曲")
        case .selectNextRow: return String(localized: "选择下一首歌曲")
        case .playSelectedRow: return String(localized: "播放选中歌曲")
        }
    }

    public var defaultShortcut: UserShortcut {
        switch self {
        case .togglePlayPause: return UserShortcut(key: " ", modifiers: [])
        // Follow Vim's down/up direction for moving through the playback queue.
        case .nextTrack: return UserShortcut(key: "j", modifiers: [])
        case .previousTrack: return UserShortcut(key: "k", modifiers: [])
        case .cycleRepeatMode: return UserShortcut(key: "r", modifiers: [])
        case .toggleLike: return UserShortcut(key: "l", modifiers: [])
        case .toggleLyrics: return UserShortcut(key: "y", modifiers: [])
        case .toggleQueue: return UserShortcut(key: "q", modifiers: [])
        case .toggleComments: return UserShortcut(key: "c", modifiers: [])
        case .closeImmersive: return UserShortcut(key: "\u{1B}", modifiers: [])
        case .volumeUp: return UserShortcut(key: "=", modifiers: [])
        case .volumeDown: return UserShortcut(key: "-", modifiers: [])
        case .searchPlaylist: return UserShortcut(key: "f", modifiers: [])
        case .searchLibrary: return UserShortcut(key: "f", modifiers: .shift)
        case .toggleNowPlaying: return UserShortcut(key: "p", modifiers: [])
        case .toggleMute: return UserShortcut(key: "m", modifiers: [])
        case .seekBackward: return UserShortcut(key: "\u{F702}", modifiers: [])
        case .seekForward: return UserShortcut(key: "\u{F703}", modifiers: [])
        case .toggleDesktopLyrics: return UserShortcut(key: "y", modifiers: .shift)
        case .selectPreviousRow: return UserShortcut(key: "\u{F700}", modifiers: [])
        case .selectNextRow: return UserShortcut(key: "\u{F701}", modifiers: [])
        case .playSelectedRow: return UserShortcut(key: "\r", modifiers: [])
        }
    }
}

private struct ShortcutBindings: Codable, Equatable {
    var app: [ShortcutAction: UserShortcut]

    private enum CodingKeys: CodingKey { case app }

    init(app: [ShortcutAction: UserShortcut]) {
        self.app = app
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try container.nestedUnkeyedContainer(forKey: .app)
        app = [:]
        // Enum-keyed dictionaries encode as alternating key/value pairs. Discard only
        // the removed action so its old binding cannot invalidate the remaining keys.
        while !entries.isAtEnd {
            let rawAction = try entries.decode(String.self)
            let shortcut = try entries.decode(UserShortcut.self)
            guard rawAction != "cycleQueueOrder" else { continue }
            guard let action = ShortcutAction(rawValue: rawAction) else {
                throw DecodingError.dataCorruptedError(in: entries,
                    debugDescription: "Unknown shortcut action: \(rawAction)")
            }
            app[action] = shortcut
        }
    }

    static var defaults: Self {
        Self(app: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) }))
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager(userDefaults: .standard)

    @Published private var bindings = ShortcutBindings.defaults
    var appShortcuts: [ShortcutAction: UserShortcut] { bindings.app }

    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "Kumone", category: "Shortcuts")
    static let bindingsKey = "settings.shortcuts"
    private let appPrefix = "settings.shortcut."

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        loadShortcuts()
    }

    private func loadShortcuts() {
        do {
            if let data = userDefaults.data(forKey: Self.bindingsKey) {
                bindings = completing(try JSONDecoder().decode(ShortcutBindings.self, from: data))
            } else {
                var migrated = ShortcutBindings.defaults
                for action in ShortcutAction.allCases {
                    if let data = userDefaults.data(forKey: appPrefix + action.rawValue) {
                        migrated.app[action] = try JSONDecoder().decode(UserShortcut.self, from: data)
                    }
                }
                migrated = completing(migrated)
                let data = try JSONEncoder().encode(migrated)
                userDefaults.set(data, forKey: Self.bindingsKey)
                bindings = migrated
                for action in ShortcutAction.allCases {
                    userDefaults.removeObject(forKey: appPrefix + action.rawValue)
                }
            }
        } catch {
            // Retain unreadable stored data; defaults keep the app usable until the user replaces it.
            logger.error("Cannot load shortcuts: \(error.localizedDescription)")
            ToastCenter.shared.show(String(localized: "无法读取快捷键，暂用默认设置"))
        }
    }

    func setShortcut(_ shortcut: UserShortcut, for action: ShortcutAction) throws {
        let shortcut = shortcut.normalized
        if let conflict = conflictDescription(for: shortcut, excluding: action) {
            throw ShortcutConflict(message: conflict)
        }
        guard shortcut != self.shortcut(for: action) else { return }
        var updated = bindings
        updated.app[action] = shortcut
        let data = try JSONEncoder().encode(updated)
        userDefaults.set(data, forKey: Self.bindingsKey)
        bindings = updated
    }

    func clearShortcut(for action: ShortcutAction) throws {
        try setShortcut(.unassigned, for: action)
    }

    func resetToDefaults() throws {
        let defaults = ShortcutBindings.defaults
        let data = try JSONEncoder().encode(defaults)
        userDefaults.set(data, forKey: Self.bindingsKey)
        if bindings != defaults { bindings = defaults }
    }

    func shortcut(for action: ShortcutAction) -> UserShortcut {
        appShortcuts[action] ?? action.defaultShortcut
    }

    private struct ShortcutConflict: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func conflictDescription(for shortcut: UserShortcut, excluding action: ShortcutAction) -> String? {
        let shortcut = shortcut.normalized
        guard !shortcut.key.isEmpty else { return nil }
        if let other = ShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0).normalized == shortcut
        }) {
            return String(localized: "已用于「\(other.displayName)」，请换一个按键。")
        }
        if shortcut.modifiers == .command {
            // Native editing, window and navigation commands must remain reachable.
            let reserved = ["a", "c", "v", "x", "z", "q", "w", "h", "m", ",", "[", "]", " ", "\t"]
            if reserved.contains(shortcut.key) || Int(shortcut.key).map({ (1...9).contains($0) }) == true {
                return String(localized: "此组合键用于系统或页面操作，请换一个按键。")
            }
        }
        if shortcut.modifiers == [.command, .shift], ["z", "3", "4", "5", "\t"].contains(shortcut.key) {
            return String(localized: "此组合键用于系统或页面操作，请换一个按键。")
        }
        if shortcut.modifiers == [.command, .control], shortcut.key == "f" {
            return String(localized: "此组合键用于系统或页面操作，请换一个按键。")
        }
        return nil
    }

    private func completing(_ stored: ShortcutBindings) -> ShortcutBindings {
        var result = stored
        for action in ShortcutAction.allCases {
            if let shortcut = result.app[action] { result.app[action] = shortcut.normalized }
        }
        // Keep explicit clears and custom keys. A newly added default must not
        // steal a key that an existing installation already assigned elsewhere.
        for action in ShortcutAction.allCases where result.app[action] == nil {
            let proposed = action.defaultShortcut
            result.app[action] = result.app.values.contains(proposed) ? .unassigned : proposed
        }
        return result
    }

    // MARK: - App-internal Key Event Matching (local monitor only)

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let currentModifiers = UserShortcut.ShortcutModifiers(nsFlags: event.modifierFlags)

        // We handle some keys only if not editing text
        let editingText = event.window?.firstResponder is NSText

        // Match against registered app shortcuts only
        for action in ShortcutAction.allCases {
            let shortcut = self.shortcut(for: action)
            guard !shortcut.key.isEmpty else { continue }
            if editingText {
                if shortcut.modifiers.isEmpty || (!shortcut.modifiers.contains(.command) && !shortcut.modifiers.contains(.control)) {
                    continue
                }
            }

            if event.charactersIgnoringModifiers?.lowercased() == shortcut.key && currentModifiers == shortcut.modifiers {
                return executeAction(action, in: event.window)
            }
        }

        return false
    }

    @discardableResult
    func executeAction(_ action: ShortcutAction, in window: NSWindow? = nil) -> Bool {
        let window = window ?? NSApp.keyWindow
        let player = PlayerService.shared
        switch action {
        case .searchLibrary:
            guard window === AppDelegate.shared?.mainWindow, window != nil, window?.attachedSheet == nil else { return false }
            player.showNowPlaying = false
            NotificationCenter.default.post(name: .focusLibrarySearch, object: window)
            return true
        case .searchPlaylist, .selectPreviousRow, .selectNextRow, .playSelectedRow:
            guard !player.showNowPlaying, window?.attachedSheet == nil,
                  let table = window?.contentView?.descendant(of: TrackTable.SongTable.self,
                      matching: { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }) else { return false }
            switch action {
            case .searchPlaylist: return table.focusSearch?() == true
            case .selectPreviousRow: return table.moveSelection?(false) == true
            case .selectNextRow: return table.moveSelection?(true) == true
            default: return table.activateSelection?() == true
            }
        default: break
        }
        Task { @MainActor in
            switch action {
            case .togglePlayPause:
                player.togglePlayPause()
            case .nextTrack:
                player.next()
            case .previousTrack:
                player.previous()
            case .cycleRepeatMode:
                player.cyclePlaybackMode()
            case .toggleLike:
                if let track = player.currentTrack {
                    await AccountStore.shared.toggleLike(trackID: track.id)
                }
            case .toggleLyrics:
                player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
            case .toggleQueue:
                player.activePanel = player.activePanel == .queue ? nil : .queue
            case .toggleComments:
                guard player.hasCurrentTrack else { return }
                player.activePanel = player.activePanel == .comments ? nil : .comments
            case .closeImmersive:
                player.dismissPlaybackPresentation()
            case .volumeUp:
                player.volume = min(player.volume + 0.1, 1.0)
            case .volumeDown:
                player.volume = max(player.volume - 0.1, 0.0)
            case .toggleNowPlaying:
                guard player.hasCurrentTrack else { return }
                withAnimation(AppAnimation.smooth) { player.showNowPlaying.toggle() }
            case .toggleMute:
                player.toggleMute()
            case .seekBackward, .seekForward:
                guard player.hasCurrentTrack, player.duration > 0 else { return }
                player.seek(to: min(player.duration, max(0, player.progress + (action == .seekForward ? 5 : -5))))
            case .toggleDesktopLyrics:
                SettingsManager.shared.showDesktopLyrics.toggle()
            case .searchLibrary, .searchPlaylist, .selectPreviousRow, .selectNextRow, .playSelectedRow:
                break // Contextual actions are delivered synchronously above.
            }
        }
        return true
    }
}
