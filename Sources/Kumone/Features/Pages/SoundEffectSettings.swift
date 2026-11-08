import SwiftUI

/// Settings and the player popover share the same controls and live state.
struct SoundEffectSettings: View {
    var body: some View { SoundEffectPanel() }
}

struct SoundEffectPanel: View {
    var onLogin: (() -> Void)? = nil
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var account = AccountStore.shared
    @AppStorage("settings.lastEnabledSoundEffectMode") private var lastEnabledMode = ""
    @State private var showsPreferences = false

    private var enabled: Bool { settings.soundEffectMode != .off }
    private var signedIn: Bool { account.authenticatedAccountID != nil }
    private var resumeMode: SoundEffectMode? {
        guard signedIn else { return nil }
        if let saved = SoundEffectMode(rawValue: lastEnabledMode), saved != .off { return saved }
        if account.membershipTier >= .svip { return .aiMaster }
        if account.membershipTier >= .vip { return .smart }
        return nil
    }
    private var canResume: Bool {
        guard let mode = resumeMode, mode.minimumMembership <= account.membershipTier else { return false }
        if mode == .preset {
            return player.soundEffectPresets.first(where: { $0.id == settings.soundEffectPresetID })?
                .canUse(tier: account.membershipTier) == true
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !signedIn || (enabled && ![.off, .waiting, .ready].contains(player.soundEffectState)) {
                status
            }
            VStack(spacing: 2) {
                modeRow(.aiMaster, icon: "wand.and.stars")
                if settings.soundEffectMode == .aiMaster {
                    tuningPreferences
                }
                modeRow(.smart, icon: "waveform")
                modeRow(.emotion, icon: "sparkles")
            }
            if signedIn {
                Divider()
                presetCatalog
            }
        }
        .font(.system(size: 13))
        .tint(Theme.accent)
        .onAppear {
            rememberSelection(settings.soundEffectMode)
            player.loadSoundEffectCatalog()
        }
        .onChange(of: settings.soundEffectMode) { _, mode in rememberSelection(mode) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("音效").font(.system(size: 14, weight: .semibold))
            if enabled {
                Text(player.selectedSoundEffectName)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("启用音效", isOn: Binding(get: { enabled }, set: { active in
                if active, let mode = resumeMode { player.setSoundEffectMode(mode) }
                else if !active { player.setSoundEffectMode(.off) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(!enabled && !canResume)
            .accessibilityIdentifier("sound-effect-toggle")
            .help("启用音效")
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            if enabled && player.soundEffectState == .loading {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 15, height: 15)
            } else {
                Image(systemName: statusIcon).font(.system(size: 12))
                    .foregroundStyle(player.soundEffectState == .ready && enabled ? Theme.accent : .secondary)
                    .frame(width: 15, height: 15)
            }
            Text(signedIn ? player.soundEffectState.displayName : String(localized: "登录后可使用音效"))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !signedIn, let onLogin {
                Button("登录", action: onLogin).buttonStyle(.borderless).font(.system(size: 12))
            } else if signedIn && enabled && [.failed, .offlineMissing, .unauthorized].contains(player.soundEffectState) {
                Button("重试") { player.refreshSoundEffect(retry: true) }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sound-effect-status")
    }

    private var statusIcon: String {
        guard enabled else { return "info.circle" }
        switch player.soundEffectState {
        case .ready: return "waveform.circle.fill"
        case .requiresLogin, .requiresSVIP, .unauthorized: return "lock"
        case .offlineMissing: return "wifi.slash"
        case .failed, .unavailable, .unsupportedSource: return "exclamationmark.circle"
        default: return "info.circle"
        }
    }

    private var tuningPreferences: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppAnimation.quick) { showsPreferences.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("个性偏好")
                    Spacer()
                    Text(preferenceSummary).foregroundStyle(.secondary)
                    Image(systemName: showsPreferences ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.leading, 38)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.interactiveRow)
            .accessibilityIdentifier("sound-effect-preferences")
            .accessibilityValue(showsPreferences ? String(localized: "已展开") : String(localized: "已收起"))
            if showsPreferences { preferences.padding(.horizontal, 10).padding(.vertical, 6) }
        }
    }

    private var preferenceSummary: String {
        settings.aiTuningPreferences.isEmpty ? String(localized: "默认")
            : String(localized: "已选 \(settings.aiTuningPreferences.count) 项")
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("调音强度").font(.system(size: 11))
                Slider(value: Binding(get: { settings.aiSoundEffectStrength }, set: player.setAISoundEffectStrength),
                       in: 0...1, step: 0.05)
                    .accessibilityLabel("调音强度")
                Text(settings.aiSoundEffectStrength, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11)).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())],
                      alignment: .leading, spacing: 2) {
                ForEach(AITuningPreference.allCases) { preference in
                    let selected = settings.aiTuningPreferences.contains(preference)
                    PopupRow(isSelected: selected) {
                        player.setAITuningPreference(preference, enabled: !selected)
                    } content: {
                        Text(preference.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel(preference.title)
                    .accessibilityValue(selected ? String(localized: "已选择") : String(localized: "未选择"))
                }
            }
            // The service reports preferences rejected for this song; keep the
            // saved choice visible while explaining why it is not being applied.
            ForEach(AITuningPreference.allCases.filter { player.closedTuningPreferences[$0] != nil }) { preference in
                if let reason = player.closedTuningPreferences[preference] {
                    Text(preference.title + "：" + reason)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("重置偏好") { player.resetAITuningPreferences() }
                .buttonStyle(.borderless).font(.system(size: 11))
                .disabled(settings.aiTuningPreferences.isEmpty && settings.aiSoundEffectStrength == 1)
        }
        .disabled(!signedIn || account.membershipTier < .svip)
    }

    private func modeRow(_ mode: SoundEffectMode, icon: String) -> some View {
        let allowed = signedIn && account.membershipTier >= mode.minimumMembership
        let selected = settings.soundEffectMode == mode
        return PopupRow(isSelected: selected, action: { player.setSoundEffectMode(mode) }) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(mode.title)
                Spacer(minLength: 0)
                Text(mode.minimumMembership.displayName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !allowed {
                    Image(systemName: "lock")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!allowed)
        .accessibilityLabel(mode.title + "，" + mode.minimumMembership.displayName)
        .accessibilityValue(selected ? String(localized: "已选择") : allowed ? String(localized: "可用") : String(localized: "暂无权益"))
    }

    private var presetCatalog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("音效列表").font(.system(size: 12, weight: .semibold))
                Spacer()
                if signedIn {
                    if player.soundEffectCatalogLoading { ProgressView().controlSize(.mini) }
                    else {
                        Button { player.loadSoundEffectCatalog(refresh: true) } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless).help("重新加载音效列表")
                        .accessibilityLabel("重新加载音效列表")
                    }
                }
            }
            .padding(.horizontal, 10)
            if signedIn && player.soundEffectPresets.isEmpty {
                Text(player.soundEffectCatalogLoading ? String(localized: "正在加载音效…")
                     : player.soundEffectCatalogFailed ? String(localized: "音效列表加载失败，请重试")
                     : String(localized: "暂无可用音效"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            } else if signedIn {
                if player.soundEffectCatalogFailed {
                    Text("音效列表加载失败，请重试")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 2) {
                    ForEach(player.soundEffectPresets) { preset in presetCard(preset) }
                }
            }
        }
    }

    private func presetCard(_ preset: SoundEffectPreset) -> some View {
        let selected = settings.soundEffectMode == .preset && settings.soundEffectPresetID == preset.id
        let allowed = signedIn && preset.canUse(tier: account.membershipTier)
        return Button { player.selectSoundEffectPreset(preset) } label: {
            HStack(spacing: 6) {
                Text(preset.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                if preset.membership != .free {
                    Text(preset.membership.displayName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !allowed { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SoundEffectRowBackground(isSelected: selected))
        .disabled(!allowed)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(preset.name + "，" + preset.membership.displayName)
        .accessibilityValue(selected ? String(localized: "已选择") : allowed ? String(localized: "可用") : String(localized: "暂无权益"))
        .help(preset.name)
    }

    private func rememberSelection(_ mode: SoundEffectMode) {
        if mode != .off { lastEnabledMode = mode.rawValue }
    }
}

/// Keep the richer sound effect layouts on the same selection and hover surface as menu rows.
private struct SoundEffectRowBackground: ViewModifier {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(PopupRowBackground(isSelected: isSelected,
                                           isHighlighted: isEnabled && isHighlighted))
            .onHover { isHighlighted = $0 }
    }
}

extension Notification.Name {
    static let showSoundEffectSettings = Notification.Name("Liltiva.showSoundEffectSettings")
}
