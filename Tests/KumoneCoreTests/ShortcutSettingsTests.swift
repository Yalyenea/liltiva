import AppKit
import Combine
import Foundation
import Testing
@testable import KumoneCore

@Suite @MainActor
struct ShortcutSettingsTests {
    @Test func escapeLeavesSearchBeforeClosingThePlaybackPanel() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = ShortcutSearchField.Field()
        window.contentView = field
        var exits = 0
        field.exit = { exits += 1 }
        field.focusAndSelect()
        let player = PlayerService.shared
        let original = player.activePanel
        defer { player.activePanel = original }
        player.activePanel = .queue
        let escape = try keyEvent(code: 53, key: "\u{1B}", windowNumber: window.windowNumber)
        #expect(AppDelegate.interceptKeyEvent(escape) == nil)
        #expect(exits == 1)
        #expect(player.activePanel == .queue)
    }

    @Test func oldBindingsReceiveNewActionsWithoutStealingCustomKeys() throws {
        let suite = "liltiva-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = try JSONSerialization.data(withJSONObject: ["app": [
            "toggleLike", ["key": "f", "modifiers": 0],
            "toggleQueue", ["key": "", "modifiers": 0]
        ]])
        defaults.set(stored, forKey: ShortcutManager.bindingsKey)
        let manager = ShortcutManager(userDefaults: defaults)
        #expect(manager.shortcut(for: .toggleLike) == UserShortcut(key: "f", modifiers: []))
        #expect(manager.shortcut(for: .searchPlaylist) == .unassigned)
        #expect(manager.shortcut(for: .searchLibrary) == UserShortcut(key: "f", modifiers: .shift))
        #expect(manager.shortcut(for: .toggleQueue) == .unassigned)
        #expect(manager.shortcut(for: .toggleComments) == UserShortcut(key: "c", modifiers: []))
        #expect(manager.appShortcuts.count == ShortcutAction.allCases.count)
        // New defaults are available to the actual event matcher, not just the settings labels.
        #expect(!manager.handleKeyEvent(try keyEvent(code: 46, key: "M", flags: .shift)))
    }

    @Test func duplicateAndReservedBindingsAreRejectedWithoutChangingSavedData() throws {
        let suite = "liltiva-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(userDefaults: defaults)
        let saved = defaults.data(forKey: ShortcutManager.bindingsKey)
        #expect(throws: (any Error).self) {
            try manager.setShortcut(UserShortcut(key: "F", modifiers: []), for: .nextTrack)
        }
        for key in ["q", "c", "[", "1"] {
            #expect(throws: (any Error).self) {
                try manager.setShortcut(UserShortcut(key: key, modifiers: .command), for: .nextTrack)
            }
        }
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) == saved)
        try manager.setShortcut(UserShortcut(key: "N", modifiers: .shift), for: .nextTrack)
        #expect(manager.shortcut(for: .nextTrack) == UserShortcut(key: "n", modifiers: .shift))
    }

    @Test func typingKeepsLettersShiftedLettersSpaceAndArrowsInTheEditor() throws {
        let suite = "liltiva-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(userDefaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView()
        window.contentView = editor
        try #require(window.makeFirstResponder(editor))
        for (key, code, flags) in [("f", UInt16(3), NSEvent.ModifierFlags()), ("F", 3, .shift),
                                    ("c", 8, []), ("Y", 16, .shift), (" ", 49, []), ("\u{F702}", 123, [])] {
            #expect(!manager.handleKeyEvent(try keyEvent(code: code, key: key, flags: flags,
                                                        windowNumber: window.windowNumber)))
        }
    }

    @Test func muteRestoresLatestNonzeroVolume() {
        let player = PlayerService.shared
        let original = player.volume
        defer { player.volume = original }
        player.volume = 0.37
        player.toggleMute()
        #expect(player.volume == 0)
        player.toggleMute()
        #expect(player.volume == 0.37)
        player.volume = 0.64
        player.volume = 0
        player.toggleMute()
        #expect(player.volume == 0.64)
    }

    @Test func removingQueueOrderPreservesCustomAndDisabledBindings() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = try JSONSerialization.data(withJSONObject: ["app": [
            "cycleQueueOrder", ["key": "s", "modifiers": 0],
            "nextTrack", ["key": "n", "modifiers": 4],
            "toggleLike", ["key": "", "modifiers": 0]
        ]])
        defaults.set(stored, forKey: ShortcutManager.bindingsKey)

        let manager = ShortcutManager(userDefaults: defaults)
        #expect(manager.shortcut(for: .nextTrack) == UserShortcut(key: "n", modifiers: .option))
        #expect(manager.shortcut(for: .toggleLike) == .unassigned)
        #expect(!manager.handleKeyEvent(try keyEvent(code: 1, key: "s")))

        try manager.setShortcut(UserShortcut(key: "w", modifiers: []), for: .toggleQueue)
        let saved = try #require(defaults.data(forKey: ShortcutManager.bindingsKey))
        #expect(!String(decoding: saved, as: UTF8.self).contains("cycleQueueOrder"))
        let restored = ShortcutManager(userDefaults: defaults)
        #expect(restored.appShortcuts == manager.appShortcuts)
    }

    @Test func escapeClosesLyricsAndQueueBeforeThePlaybackPage() throws {
        let player = PlayerService.shared
        let originalPanel = player.activePanel
        let originalPage = player.showNowPlaying
        defer {
            player.activePanel = originalPanel
            player.showNowPlaying = originalPage
        }
        let escape = try keyEvent(code: 53, key: "\u{1B}")

        for panel in [RightPanel.lyrics, .queue, .comments] {
            for showPage in [false, true] {
                player.activePanel = panel
                player.showNowPlaying = showPage

                #expect(AppDelegate.interceptKeyEvent(escape) == nil)
                #expect(player.activePanel == nil)
                #expect(player.showNowPlaying == showPage)
                if showPage {
                    #expect(AppDelegate.interceptKeyEvent(escape) == nil)
                    #expect(!player.showNowPlaying)
                }
            }
        }
    }

    @Test func modifiedEscapeDoesNotDismissPlaybackSurfaces() throws {
        let player = PlayerService.shared
        let originalPanel = player.activePanel
        let originalPage = player.showNowPlaying
        defer {
            player.activePanel = originalPanel
            player.showNowPlaying = originalPage
        }
        player.activePanel = .queue
        player.showNowPlaying = true

        for flags in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            let escape = try keyEvent(code: 53, key: "\u{1B}", flags: flags)
            #expect(AppDelegate.interceptKeyEvent(escape) === escape)
            #expect(player.activePanel == .queue)
            #expect(player.showNowPlaying)
        }
    }

    @Test func migratesLegacyBindingsIncludingExplicitlyDisabledDefaults() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(UserShortcut.unassigned), forKey: "settings.shortcut.nextTrack")
        // Removed global preferences must not block migration of local bindings.
        defaults.set(Data("obsolete global shortcut".utf8), forKey: "settings.globalShortcut.toggleLike")

        let manager = ShortcutManager(userDefaults: defaults)
        #expect(manager.shortcut(for: .nextTrack) == .unassigned)
        #expect(manager.shortcut(for: .toggleLike) == ShortcutAction.toggleLike.defaultShortcut)
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) != nil)
        #expect(defaults.object(forKey: "settings.shortcut.nextTrack") == nil)
        let restored = ShortcutManager(userDefaults: defaults)
        #expect(restored.appShortcuts == manager.appShortcuts)
    }

    @Test func resetPublishesOnceAndRestoresAppBindingsPersistently() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(userDefaults: defaults)
        try manager.clearShortcut(for: .nextTrack)
        try manager.setShortcut(UserShortcut(key: "j", modifiers: [.control]), for: .toggleLike)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        try manager.resetToDefaults()
        #expect(publications == 1)
        let restored = ShortcutManager(userDefaults: defaults)
        for action in ShortcutAction.allCases {
            #expect(restored.shortcut(for: action) == action.defaultShortcut)
        }
        try manager.resetToDefaults()
        #expect(publications == 1)
    }

    @Test func storedAppBindingsIgnoreRemovedGlobalScopeAndPersistEdits() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = UserShortcut(key: "k", modifiers: [.option])
        let app: [ShortcutAction: UserShortcut] = [.toggleLike: original, .nextTrack: .unassigned]
        let appData = try JSONEncoder().encode(app)
        let appJSON = try JSONSerialization.jsonObject(with: appData)
        // The old combined payload can retain any global value; only app bindings are decoded.
        let stored = try JSONSerialization.data(withJSONObject: ["app": appJSON, "global": "removed"])
        defaults.set(stored, forKey: ShortcutManager.bindingsKey)
        let manager = ShortcutManager(userDefaults: defaults)
        #expect(manager.shortcut(for: .toggleLike) == original)
        #expect(manager.shortcut(for: .nextTrack) == .unassigned)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        try manager.setShortcut(original, for: .toggleLike)
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) == stored)
        #expect(publications == 0)
        try manager.clearShortcut(for: .toggleLike)
        #expect(manager.shortcut(for: .toggleLike) == .unassigned)
        #expect(publications == 1)
        let saved = try #require(defaults.data(forKey: ShortcutManager.bindingsKey))
        let savedJSON = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(savedJSON["global"] == nil)
        let restored = ShortcutManager(userDefaults: defaults)
        #expect(restored.appShortcuts == manager.appShortcuts)
    }

    @Test func resetReplacesUnreadableStoredBindingsWhileAlreadyUsingDefaults() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unreadable = Data("invalid shortcut data".utf8)
        defaults.set(unreadable, forKey: ShortcutManager.bindingsKey)
        let manager = ShortcutManager(userDefaults: defaults)
        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) == unreadable)
        var publications = 0
        let observation = manager.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        try manager.resetToDefaults()

        #expect(defaults.data(forKey: ShortcutManager.bindingsKey) != unreadable)
        #expect(publications == 0)
        let restored = ShortcutManager(userDefaults: defaults)
        #expect(restored.appShortcuts == manager.appShortcuts)
    }

    @Test func emptyKeyEventsDoNotMatchUnassignedActions() throws {
        let suite = "kumone-shortcuts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(userDefaults: defaults)
        try manager.clearShortcut(for: .togglePlayPause)
        try manager.clearShortcut(for: .nextTrack)

        #expect(!manager.handleKeyEvent(try keyEvent(code: 0, key: "")))
    }

    @Test(arguments: [UInt16(51), UInt16(117)])
    func unmodifiedDeleteClearsInsteadOfRecording(code: UInt16) throws {
        let recorder = ShortcutRecorderView.RecorderNSView()
        var clears = 0
        var recorded: [String] = []
        recorder.onClear = { clears += 1 }
        recorder.onRecord = { key, _ in recorded.append(key) }

        recorder.keyDown(with: try keyEvent(code: code, key: "\u{7F}"))

        #expect(clears == 1)
        #expect(recorded.isEmpty)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift])
    func modifiedDeleteRemainsRecordable(flags: NSEvent.ModifierFlags) throws {
        let recorder = ShortcutRecorderView.RecorderNSView()
        var clears = 0
        var recorded: [UserShortcut] = []
        recorder.onClear = { clears += 1 }
        recorder.onRecord = { key, modifiers in recorded.append(UserShortcut(key: key, modifiers: modifiers)) }

        recorder.keyDown(with: try keyEvent(code: 51, key: "\u{7F}", flags: flags))
        recorder.keyDown(with: try keyEvent(code: 117, key: "\u{F728}", flags: flags))

        #expect(clears == 0)
        #expect(recorded == [
            UserShortcut(key: "\u{7F}", modifiers: .init(nsFlags: flags)),
            UserShortcut(key: "\u{F728}", modifiers: .init(nsFlags: flags))
        ])
    }

    @Test func recordingReceivesPlaybackBindingsDeleteAndEscapeBeforeAppShortcuts() throws {
        _ = NSApplication.shared
        let player = PlayerService.shared
        let originalPanel = player.activePanel
        let originalPage = player.showNowPlaying
        defer {
            player.activePanel = originalPanel
            player.showNowPlaying = originalPage
        }
        player.activePanel = .queue
        player.showNowPlaying = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = ShortcutRecorderView.RecorderNSView()
        window.contentView = recorder
        try #require(window.makeFirstResponder(recorder))
        var recorded: [UserShortcut] = []
        var clears = 0
        var cancellations = 0
        recorder.onRecord = { key, modifiers in recorded.append(UserShortcut(key: key, modifiers: modifiers)) }
        recorder.onClear = { clears += 1 }
        recorder.onCancel = { cancellations += 1 }

        let previousTrack = try keyEvent(code: 123, key: "\u{F702}", flags: .command,
                                         windowNumber: window.windowNumber)
        try #require(previousTrack.window === window)
        #expect(AppDelegate.interceptKeyEvent(previousTrack) == nil)
        #expect(recorded == [UserShortcut(key: "\u{F702}", modifiers: .command)])
        #expect(AppDelegate.interceptKeyEvent(try keyEvent(code: 51, key: "\u{7F}",
                                                        windowNumber: window.windowNumber)) == nil)
        #expect(clears == 1)
        #expect(AppDelegate.interceptKeyEvent(try keyEvent(code: 53, key: "\u{1B}",
                                                        windowNumber: window.windowNumber)) == nil)
        #expect(cancellations == 1)
        #expect(recorded.count == 1)
        #expect(player.activePanel == .queue)
        #expect(player.showNowPlaying)
    }

    private func keyEvent(code: UInt16, key: String, flags: NSEvent.ModifierFlags = [],
                          windowNumber: Int = 0) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: 0, windowNumber: windowNumber, context: nil,
                                            characters: key, charactersIgnoringModifiers: key,
                                            isARepeat: false, keyCode: code))
    }
}
