import SwiftUI
import AppKit

struct ShortcutSettingsView: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @State private var recordingAction: ShortcutAction?
    @State private var query = ""

    var body: some View {
        SettingsForm {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    TextField("筛选快捷键", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("filter-shortcuts")
                    Button("恢复默认") {
                        recordingAction = nil
                        do { try manager.resetToDefaults() }
                        catch { ToastCenter.shared.show(error.localizedDescription) }
                    }
                    .fixedSize()
                }
            }
            ForEach(ShortcutCategory.allCases) { group in
                let actions = group.actions.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
                if !actions.isEmpty {
                    SettingsSection(group.title) {
                        ForEach(actions) { action in
                            ShortcutRow(action: action,
                                    shortcut: manager.shortcut(for: action),
                                    isRecording: Binding(
                                        get: { recordingAction == action },
                                        set: { recording in
                                            if recording { recordingAction = action }
                                            else if recordingAction == action { recordingAction = nil }
                                        }
                                    ))
                        }
                    }
                }
            }
            if !query.isEmpty, !ShortcutAction.allCases.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) }) {
                Text("没有匹配的快捷键").foregroundStyle(.secondary)
            }
        }
        .onDisappear { recordingAction = nil }
    }
}

struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: UserShortcut
    @Binding var isRecording: Bool
    @FocusState private var isFocused: Bool
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(action.displayName, systemImage: action.systemImage)
                Spacer()
                Button {
                    isRecording = true
                    errorMessage = nil
                    isFocused = true
                } label: {
                    Text(isRecording ? String(localized: "录制中…") : shortcut.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(minWidth: 80)
                        .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                        .foregroundColor(isRecording ? .white : .primary)
                }
                .buttonStyle(.plain)
                .focused($isFocused)
                .help("Delete 清除 · Esc 取消")
                .accessibilityLabel(Text(action.displayName))
                .accessibilityValue(Text(isRecording ? String(localized: "录制中…") : shortcut.displayString))
                .accessibilityIdentifier("shortcut-\(action.rawValue)")
                .accessibilityHint(Text("Delete 清除 · Esc 取消"))
                .accessibilityAction(named: Text("清除快捷键"), clearShortcut)
                .contextMenu {
                    if !isRecording, !shortcut.key.isEmpty {
                        Button("清除快捷键", action: clearShortcut)
                    }
                }

                if isRecording {
                    ShortcutRecorderView(isRecording: $isRecording, onClear: clearShortcut) { key, modifiers in
                        do {
                            try ShortcutManager.shared.setShortcut(
                                UserShortcut(key: key, modifiers: modifiers), for: action)
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .frame(width: 0, height: 0)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func clearShortcut() {
        do {
            try ShortcutManager.shared.clearShortcut(for: action)
            errorMessage = nil
            isRecording = false
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
}

extension ShortcutAction {
    var systemImage: String {
        switch self {
        case .togglePlayPause: return "playpause"
        case .nextTrack: return "forward.end"
        case .previousTrack: return "backward.end"
        case .cycleRepeatMode: return "repeat"
        case .toggleLike: return "heart"
        case .toggleLyrics: return "quote.bubble"
        case .toggleQueue: return "list.bullet"
        case .toggleComments: return "text.bubble"
        case .closeImmersive: return "xmark.circle"
        case .volumeUp: return "speaker.wave.2"
        case .volumeDown: return "speaker.wave.1"
        case .searchPlaylist: return "line.3.horizontal.decrease"
        case .searchLibrary: return "magnifyingglass"
        case .toggleNowPlaying: return "record.circle"
        case .toggleMute: return "speaker.slash"
        case .seekBackward: return "gobackward.5"
        case .seekForward: return "goforward.5"
        case .toggleDesktopLyrics: return "inset.filled.bottomthird.square"
        case .selectPreviousRow: return "arrow.up"
        case .selectNextRow: return "arrow.down"
        case .playSelectedRow: return "return"
        }
    }
}

private enum ShortcutCategory: CaseIterable, Identifiable {
    case search, playback, presentation
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .search: return "搜索与选歌"
        case .playback: return "播放控制"
        case .presentation: return "播放界面"
        }
    }
    var actions: [ShortcutAction] {
        switch self {
        case .search: return [.searchPlaylist, .searchLibrary, .selectPreviousRow, .selectNextRow, .playSelectedRow]
        case .playback: return [.togglePlayPause, .previousTrack, .nextTrack, .seekBackward, .seekForward,
                                .cycleRepeatMode, .toggleLike, .toggleMute, .volumeUp, .volumeDown]
        case .presentation: return [.toggleNowPlaying, .toggleLyrics, .toggleDesktopLyrics, .toggleQueue,
                                    .toggleComments, .closeImmersive]
        }
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onClear: () -> Void
    let onRecord: (String, UserShortcut.ShortcutModifiers) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RecorderNSView()
        view.onRecord = { key, modifiers in
            guard isRecording else { return }
            onRecord(key, modifiers)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        view.onClear = {
            guard isRecording else { return }
            onClear()
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async {
                guard isRecording, let window = nsView.window, window.firstResponder !== nsView else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    class RecorderNSView: NSView {
        var onRecord: ((String, UserShortcut.ShortcutModifiers) -> Void)?
        var onCancel: (() -> Void)?
        var onClear: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }

            let modifiers = UserShortcut.ShortcutModifiers(nsFlags: event.modifierFlags)
            if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
                onClear?()
                return
            }

            // Try to get the key, handling special characters/function keys
            let key = event.charactersIgnoringModifiers ?? ""

            // If the key is empty, check keyCode for special keys
            if key.isEmpty {
                // Map function keys/arrows
                let specialKey: String
                switch event.keyCode {
                case 123: specialKey = "\u{F702}" // Left
                case 124: specialKey = "\u{F703}" // Right
                case 125: specialKey = "\u{F701}" // Down
                case 126: specialKey = "\u{F700}" // Up
                case 122: specialKey = "\u{F704}" // F1
                // ... add more if needed
                default: specialKey = ""
                }

                if !specialKey.isEmpty {
                    onRecord?(specialKey, modifiers)
                    return
                }
            } else {
                onRecord?(key, modifiers)
                return
            }

            super.keyDown(with: event)
        }

        override func resignFirstResponder() -> Bool {
            onCancel?()
            return super.resignFirstResponder()
        }
    }
}
