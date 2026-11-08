import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var player = PlayerService.shared
    @Environment(\.openDestination) private var openDestination
    @State private var category: SettingsCategory = .playback
    @State private var isRestarting = false

    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case playback, appearance, lyrics, storage, shortcuts, sync, about

        var id: Self { self }

        var title: String {
            switch self {
            case .playback: return String(localized: "播放")
            case .appearance: return String(localized: "外观")
            case .lyrics: return String(localized: "歌词")
            case .storage: return String(localized: "存储")
            case .shortcuts: return String(localized: "快捷键")
            case .sync: return String(localized: "账户")
            case .about: return String(localized: "关于")
            }
        }

        var icon: String {
            switch self {
            case .playback: return "play.circle"
            case .appearance: return "paintpalette"
            case .lyrics: return "text.quote"
            case .storage: return "internaldrive"
            case .shortcuts: return "keyboard"
            case .sync: return "person.crop.circle"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let showsSidebar = geometry.size.width >= 600
            HStack(spacing: 0) {
                if showsSidebar {
                    categorySidebar
                    Divider()
                }

                VStack(spacing: 0) {
                    if !showsSidebar {
                        categoryHeader
                        Divider()
                    }
                    categoryContent.id(category)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 420, idealWidth: 760, minHeight: 500, idealHeight: 650)
        .background(SettingsWindowToolbar(onClose: { category = .playback }))
        .overlay(alignment: .top) { SettingsToastOverlay() }
        .noFocusRing()
        .onReceive(NotificationCenter.default.publisher(for: .showSoundEffectSettings)) { _ in category = .playback }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .frame(width: 18)
                        Text(item.title).lineLimit(1).minimumScaleFactor(0.9)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, weight: category == item ? .medium : .regular))
                    .foregroundStyle(category == item ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .background(category == item ? Color.primary.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-\(item.rawValue)")
                .noFocusRing()
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 152)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var categoryHeader: some View {
        HStack {
            SettingsChoiceButton(title: String(localized: "设置分类"), selection: $category,
                                 options: SettingsCategory.allCases.map {
                                     .init(value: $0, title: $0.title, symbol: $0.icon)
                                 }, width: 128)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .playback:
            SettingsForm {
                SettingsSection("音质") {
                    SettingsPicker("播放音质", selection: Binding(
                        get: { account.playbackQuality },
                        set: { PlayerService.shared.setAudioQuality($0) }
                    ), width: 184, options: account.availableAudioQualities.map { .init(value: $0, title: $0.displayName) })
                    LabeledContent("账号权益", value: account.membershipTier.displayName)
                    if account.isRefreshingMembership {
                        ProgressView().controlSize(.small)
                    } else if account.membershipRefreshFailed {
                        Button("会员信息暂不可用，点击重试") { Task { await account.refreshMembership() } }
                    }
                    if let level = player.servedQuality, let actual = AudioQuality(rawValue: level) {
                        LabeledContent("当前音质", value: actual.displayName)
                    }
                }
                .task { await account.refreshMembership() }

                SoundEffectSettings()
            }

        case .appearance:
            SettingsForm {
                SettingsSection("界面") {
                    SettingsPicker("语言", selection: $settings.language,
                                   options: AppLanguage.allCases.map { .init(value: $0, title: $0.displayName) })
                    .disabled(isRestarting)
                    if settings.needsLanguageRestart {
                        HStack {
                            Text("重启后生效").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("重新启动") {
                                isRestarting = true
                                Task { @MainActor in
                                    do { try await AppDelegate.restartApplication() }
                                    catch {
                                        isRestarting = false
                                        ToastCenter.shared.show(String(localized: "无法重新启动，请退出后重新打开 Liltiva。"))
                                    }
                                }
                            }
                            .disabled(isRestarting)
                        }
                    }
                    SettingsPicker("主题", selection: $settings.appearance,
                                   options: AppAppearance.allCases.map { .init(value: $0, title: $0.displayName) })
                    SettingsPicker("播放页模式", selection: $settings.nowPlayingMode,
                                   options: NowPlayingMode.allCases.map { .init(value: $0, title: $0.displayName) })
                }

                SettingsSection("背景") {
                    Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                    if settings.showMainWindowAmbientBackground {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("背景色强度")
                                Spacer()
                                Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: $settings.mainWindowAmbientBackgroundIntensity,
                                in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                                step: 0.1
                            )
                            .accessibilityLabel("背景色强度")
                            HStack {
                                Text("50%")
                                Spacer()
                                Text("150%")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        case .lyrics:
            SettingsForm {
                SettingsSection("歌词显示") {
                    Toggle("显示翻译", isOn: $settings.showLyricsTranslation)
                    Toggle("逐字歌词", isOn: $settings.verbatimLyrics)
                    SettingsPicker("日文歌词读音", selection: $settings.lyricsAnnotation,
                                   options: LyricsAnnotation.allCases.map { .init(value: $0, title: $0.displayName) })
                }

                SettingsSection("桌面歌词") {
                    Toggle("显示桌面歌词", isOn: $settings.showDesktopLyrics)
                    if settings.showDesktopLyrics {
                        Toggle("水平居中", isOn: $settings.desktopLyricsCentered)
                    }
                }
            }

        case .storage:
            StorageSpaceView {
                openDestination(.downloaded)
            }

        case .shortcuts:
            ShortcutSettingsView()

        case .sync:
            SettingsForm {
                SyncSettingsSection()

                SettingsSection("账户") {
                    if let profile = account.profile {
                        LabeledContent("当前账户", value: profile.nickname)
                        Button("退出登录", role: .destructive) {
                            Task {
                                do { try await AccountStore.shared.logout() }
                                catch { ToastCenter.shared.show(error.localizedDescription) }
                            }
                        }
                    } else {
                        Text("未登录")
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .about:
            SettingsForm {
                SettingsSection("Liltiva") {
                    LabeledContent("版本", value: appVersion)
                    settingsHint("网易云音乐第三方客户端。数据来自网易云音乐。")
                }
            }
        }
    }

    private func settingsHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

private struct SettingsToastOverlay: View {
    @ObservedObject private var toasts = ToastCenter.shared

    var body: some View {
        Group {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .allowsHitTesting(false)
    }
}

/// Keep the settings titlebar compact and reset the category after closing.
struct SettingsWindowToolbar: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ToolbarHost {
        let view = ToolbarHost()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ToolbarHost, context: Context) {
        nsView.onClose = onClose
        nsView.updateToolbar()
    }

    final class ToolbarHost: NSView {
        var onClose: () -> Void = {}
        private var closeObserver: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeObserver = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                    .sink { [weak self] _ in self?.onClose() }
            }
            updateToolbar()
            DispatchQueue.main.async { [weak self] in
                self?.window?.clearAutoFocusIfNeeded()
            }
        }

        func updateToolbar() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                if window.toolbarStyle != .unifiedCompact || !window.styleMask.contains(.resizable) {
                    // Settings scenes omit the resize handle even with contentMinSize.
                    // Enable it here so the category layout can follow the window width.
                    window.styleMask.insert(.resizable)
                    window.toolbarStyle = .unifiedCompact
                }
                window.contentView?.disableFocusRingsRecursively()
            }
        }
    }
}
