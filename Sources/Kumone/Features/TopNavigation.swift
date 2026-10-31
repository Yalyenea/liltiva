import AppKit
import SwiftUI

final class MainWindowTitlebar: NSTitlebarAccessoryViewController {
    static let leadingInset: CGFloat = 76
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private weak var attachedWindow: NSWindow?
    private var fadedOut = false

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        host.sizingOptions = []
        host.frame.size.height = 26
        view = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(content: AnyView, in window: NSWindow) {
        attachedWindow = window
        host.rootView = content
        updateLayout(in: window)
        updateAttachment(in: window)
    }

    func updateLayout(in window: NSWindow) {
        let width = max(0, window.frame.width - Self.leadingInset)
        // AppKit can round the accessory's frame during layout; avoid another
        // window update for a difference smaller than half a backing pixel.
        guard abs(host.frame.width - width) > 0.5 / window.backingScaleFactor else { return }
        host.setFrameSize(NSSize(width: width, height: host.frame.height))
    }

    func setFadedOut(_ fadedOut: Bool) {
        self.fadedOut = fadedOut
        if let attachedWindow { updateAttachment(in: attachedWindow) }
    }

    private func updateAttachment(in window: NSWindow) {
        let index = window.titlebarAccessoryViewControllers.firstIndex { $0 === self }
        // For a right-aligned accessory, isHidden does not remove AppKit's
        // hit-testing container. Detach it while the player's header occupies
        // this row, including when SwiftUI refreshes the navigation content.
        if fadedOut {
            if let index { window.removeTitlebarAccessoryViewController(at: index) }
        } else if index == nil {
            window.addTitlebarAccessoryViewController(self)
        }
    }
}

struct MainWindowHeader: View {
    @Binding var selection: RootPage
    @Binding var showLogin: Bool
    @Binding var path: [Destination]
    let navigation: NavigationActions

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                NavigationHistoryButtons(navigation: navigation)
                Spacer(minLength: 0)
                TopNavigationBar(
                    selection: $selection,
                    windowWidth: geometry.size.width + MainWindowTitlebar.leadingInset
                ) { path.appendIfNotCurrent(.search($0)) }
                Spacer(minLength: 0)
                NavigationMenuButton(selection: $selection)
                AccountAvatarButton(showLogin: $showLogin,
                    onProfile: { path.appendIfNotCurrent(.profile($0)) },
                    onMessages: { path.appendIfNotCurrent(.messages) })
            }
            .padding(.horizontal, 6)
            .frame(height: geometry.size.height)

        }
        .frame(height: 26)
        .noFocusRing()
    }

}

struct NavigationHistoryButtons: View {
    let navigation: NavigationActions

    var body: some View {
        HStack(spacing: 2) {
            historyButton("后退", symbol: "arrow.left", enabled: navigation.canGoBack,
                          shortcut: "⌘[", action: navigation.back)
            historyButton("前进", symbol: "arrow.right", enabled: navigation.canGoForward,
                          shortcut: "⌘]", action: navigation.forward)
        }
    }

    private func historyButton(_ title: LocalizedStringKey, symbol: String, enabled: Bool,
                               shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary.opacity(enabled ? 0.8 : 0.2))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveRow)
        .noFocusRing()
        .disabled(!enabled)
        .help(Text(title) + Text("  \(shortcut)"))
        .accessibilityLabel(title)
    }
}

struct NavigationBarLayout {
    let width: CGFloat
    let searchWidth: CGFloat
    let tabsWidth: CGFloat

    init(windowWidth: CGFloat, tabsWidth: CGFloat, searchExpanded: Bool = false) {
        // Reserve room for window controls, both history buttons and account
        // actions, including their spacing at the minimum window width.
        width = max(0, windowWidth - 300)
        searchWidth = min(200, max(80, width * 0.28))
        // Reserve only the search icon until its field is actually expanded.
        let searchReservation = searchExpanded ? searchWidth : 24
        self.tabsWidth = min(tabsWidth, max(0, width - searchReservation - 18))
    }
}

struct TopNavigationBar: View {
    @Binding var selection: RootPage
    let windowWidth: CGFloat
    let onSearch: (String) -> Void

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @State private var tabsWidth: CGFloat = 0
    @State private var searchExpanded = false

    private var pages: [RootPage] {
        settings.pinnedNavigationPages.filter {
            RootPage.primaryPages.contains($0) || !$0.requiresLogin || account.hasAuthCookie
        }
    }

    var body: some View {
        let layout = NavigationBarLayout(windowWidth: windowWidth, tabsWidth: tabsWidth,
                                         searchExpanded: searchExpanded)

        HStack(spacing: 18) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                            tab(page, index: index).id(page)
                        }
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        tabsWidth = $0
                    }
                }
                .scrollIndicators(.never)
                .frame(width: layout.tabsWidth)
                .onChange(of: selection) { _, page in
                    proxy.scrollTo(page, anchor: .center)
                }
            }
            ToolbarSearchField(expandedWidth: layout.searchWidth, expanded: $searchExpanded,
                               onSubmit: onSearch)
        }
        .frame(width: layout.width, height: 26)
    }

    private func tab(_ page: RootPage, index: Int) -> some View {
        Button {
            selection = page
        } label: {
            Text(page.tabTitle)
                .font(.system(size: 13, weight: selection == page ? .semibold : .medium))
                .foregroundStyle(selection == page ? .primary : .secondary)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .keyboardShortcut(index < 9
            ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            : nil)
        .help(Text(page.title) + Text(index < 9 ? "  ⌘\(index + 1)" : ""))
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }
}

struct NavigationMenuButton: View {
    @Binding var selection: RootPage
    @EnvironmentObject private var settings: SettingsManager
    @State private var showMore = false

    var body: some View {
        Button {
            showMore.toggle()
        } label: {
            VStack(spacing: 4) {
                ForEach(0..<3) { _ in
                    Capsule().frame(width: 16, height: 1.5)
                }
            }
            .foregroundStyle(!settings.pinnedNavigationPages.contains(selection) || showMore ? .primary : .secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .help("更多")
        .accessibilityLabel("更多")
        .popover(isPresented: $showMore, arrowEdge: .bottom) {
            MorePanel(selection: $selection)
                .noFocusRing()
                .presentationBackground(Platform.windowBackgroundColor)
        }
    }
}

// MARK: - More panel

private struct MorePanel: View {
    @Binding var selection: RootPage
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RootPage.navigationPages.filter {
                RootPage.primaryPages.contains($0) || !$0.requiresLogin || account.hasAuthCookie
            }) { page in
                MorePanelRow(page: page, isSelected: selection == page) {
                    selection = page
                    dismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 230)
    }
}

private struct MorePanelRow: View {
    let page: RootPage
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsManager
    @State private var isHovering = false

    private var isPinned: Bool { settings.pinnedNavigationPages.contains(page) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: page.symbol)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(page.title)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            Button {
                page.togglePin(in: &settings.pinnedNavigationPages)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(isPinned ? Theme.accent : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(isPinned ? "从顶栏移除" : "固定到顶栏")
            .accessibilityLabel(isPinned ? "从顶栏移除" : "固定到顶栏")
            .accessibilityValue(Text(page.title))
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(.primary.opacity(isSelected ? 0.1 : (isHovering ? 0.06 : 0)))
        )
        .onHover { isHovering = $0 }
    }
}

// MARK: - Search field

struct ToolbarSearchField: View {
    let expandedWidth: CGFloat
    @Binding var expanded: Bool
    let onSubmit: (String) -> Void

    @State private var text = ""
    @State private var placeholder = String(localized: "搜索音乐、歌手、专辑")
    @State private var placeholderQuery = ""
    @State private var focusRequest = 0
    @ObservedObject private var shortcuts = ShortcutManager.shared
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if expanded {
                    collapse()
                } else {
                    focusSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .help(Text(expanded ? String(localized: "收起搜索") : String(localized: "全局搜索"))
                  + Text("  \(shortcuts.shortcut(for: .searchLibrary).displayString)"))
            .accessibilityLabel(expanded ? "收起搜索" : "搜索")

            ShortcutSearchField(text: $text, placeholder: placeholder, focusRequest: focusRequest,
                onSubmit: {
                    let query = text.trimmingCharacters(in: .whitespaces)
                    let effective = query.isEmpty ? placeholderQuery : query
                    if !effective.isEmpty { onSubmit(effective) }
                    collapse()
                }, onExit: collapse)
                .frame(minWidth: 0)
                .opacity(expanded ? 1 : 0)
                .disabled(!expanded)
                .accessibilityHidden(!expanded)
        }
        .padding(.trailing, expanded ? 10 : 0)
        .frame(width: expanded ? expandedWidth : 24, height: 26)
        .background(.primary.opacity(expanded ? 0.06 : 0), in: Capsule())
        .clipShape(Capsule())
        .onReceive(NotificationCenter.default.publisher(for: .focusLibrarySearch)) { _ in focusSearch() }
        .task(id: account.socialSession) {
            let binding = DiscoveryCacheContext.current
            let cached = await PageDataCache.shared.load(String.self, key: "search.default-keyword", scope: "public")
            if let cached, !cached.value.isEmpty, binding == .current {
                placeholder = cached.value
                placeholderQuery = cached.value
            }
            if let keyword = try? await binding.fetch(String.self, key: "search.default-keyword", publicData: true,
                maxAge: 6 * 60 * 60, force: cached?.value.isEmpty == true, loader: {
                    guard let keyword = try await NeteaseAPI.searchDefaultKeyword(), !keyword.isEmpty else {
                        throw URLError(.zeroByteResource)
                    }
                    return keyword
                }), binding == .current {
                placeholder = keyword
                placeholderQuery = keyword
            }
        }
    }

    private func collapse() {
        withAnimation(.easeInOut(duration: 0.24)) { expanded = false }
        text = ""
        AppDelegate.shared?.mainWindow?.makeFirstResponder(nil)
    }

    private func focusSearch() {
        withAnimation(.easeInOut(duration: 0.24), completionCriteria: .logicallyComplete) {
            expanded = true
        } completion: {
            if expanded { focusRequest += 1 }
        }
    }
}

// MARK: - Toolbar account

struct AccountAvatarButton: View {
    @Binding var showLogin: Bool
    var onProfile: (Int) -> Void = { _ in }
    var onMessages: () -> Void = {}
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var messages = MessageCenterStore.shared
    @Environment(\.openSettings) private var openSettings
    @State private var avatarImage: PlatformImage?
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            avatar(diameter: 28)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .help("账户与设置")
        .accessibilityLabel("账户与设置")
        .accessibilityValue(Text("\(messages.unread) 条未读"))
        .overlay(alignment: .topTrailing) {
            if messages.unread > 0 {
                Circle().fill(Theme.accent).frame(width: 7, height: 7).allowsHitTesting(false)
            }
        }
        .task(id: account.socialSession) { await messages.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await messages.refresh() }
        }
        .onChange(of: showPopover) { _, showing in
            if showing { Task { await messages.refresh() } }
        }
        .task(id: account.profile?.avatarUrl) {
            avatarImage = nil
            if let url = account.profile?.avatarUrl?.resizedImageURL(96) {
                avatarImage = await ImageCache.shared.image(for: url)
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            accountCard
                .noFocusRing()
                .presentationBackground(Platform.windowBackgroundColor)
        }
    }

    @ViewBuilder
    private func avatar(diameter: CGFloat) -> some View {
        if let avatarImage {
            // Clip the existing pixels without allocating another image on
            // each account view update.
            Image(platformImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: diameter - 2))
                .foregroundStyle(.tertiary)
                .frame(width: diameter, height: diameter)
        }
    }

    private var accountCard: some View {
        VStack(spacing: 12) {
            if let profile = account.profile {
                avatar(diameter: 48)
                VStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.nickname)
                            .font(.system(size: 14, weight: .semibold))
                        if profile.vipType > 0 {
                            VIPBadge()
                        }
                    }
                    if let signature = profile.signature, !signature.isEmpty {
                        Text(signature)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                Divider().opacity(0.4)
                Button {
                    showPopover = false
                    onProfile(profile.userId)
                } label: {
                    Label("个人主页", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.buttonStyle(.plain)
                Button {
                    showPopover = false
                    onMessages()
                } label: {
                    HStack {
                        Label("消息中心", systemImage: "bell")
                        Spacer()
                        if messages.unread > 0 { UnreadCountBadge(count: messages.unread) }
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().opacity(0.4)
                Button {
                    Task {
                        do {
                            try await account.logout()
                            showPopover = false
                        } catch { ToastCenter.shared.show(error.localizedDescription) }
                    }
                } label: {
                    Text("退出登录")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
            } else {
                Text("登录后同步你的音乐")
                    .font(.headline)
                SyncedLoginButtons(onStart: { showPopover = false })
                Button("登录网易云音乐") {
                    showPopover = false
                    showLogin = true
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            Button {
                showPopover = false
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
        .padding(16)
        .frame(width: 220)
        .noFocusRing()
    }
}
