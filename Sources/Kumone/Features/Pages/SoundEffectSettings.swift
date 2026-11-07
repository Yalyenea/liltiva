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
        VStack(alignment: .leading, spacing: 18) {
            header
            status
            aiMasterCard
            VStack(spacing: 8) {
                modeCard(.smart, icon: "waveform", subtitle: "随歌曲自动匹配音效")
                modeCard(.emotion, icon: "sparkles", subtitle: "根据歌曲情绪调音")
            }
            presetCatalog
            Text("采用官方音效数据，由 Liltiva 本地处理，听感可能与官方客户端有差异。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("音效").font(.system(size: 20, weight: .semibold))
                Text(enabled ? player.selectedSoundEffectName : String(localized: "音效已关闭"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("启用音效", isOn: Binding(get: { enabled }, set: { active in
                if active, let mode = resumeMode { player.setSoundEffectMode(mode) }
                else if !active { player.setSoundEffectMode(.off) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(!enabled && !canResume)
            .accessibilityIdentifier("sound-effect-toggle")
            .help(enabled || canResume ? String(localized: "启用音效") : String(localized: "选择下方可用音效以开启"))
        }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText).font(.system(size: 12))
                if enabled, let emotion = player.soundEffectEmotionLabel, !emotion.isEmpty {
                    Text(emotion).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !signedIn, let onLogin {
                Button("登录", action: onLogin).buttonStyle(.borderless).font(.system(size: 12))
            } else if signedIn && enabled && [.failed, .offlineMissing, .unauthorized].contains(player.soundEffectState) {
                Button("重试") { player.refreshSoundEffect(retry: true) }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sound-effect-status")
    }

    private var statusText: String {
        guard signedIn else { return String(localized: "登录后可使用音效") }
        if enabled { return player.soundEffectState.displayName }
        if canResume, let mode = resumeMode {
            let name = mode == .preset
                ? player.soundEffectPresets.first(where: { $0.id == settings.soundEffectPresetID })?.name ?? mode.title
                : mode.title
            return String(localized: "开启后使用：") + name
        }
        return String(localized: "选择下方可用音效以开启")
    }

    private var statusIcon: String {
        guard enabled else { return "info.circle" }
        switch player.soundEffectState {
        case .ready: return "checkmark.circle.fill"
        case .requiresLogin, .requiresSVIP, .unauthorized: return "lock"
        case .offlineMissing: return "wifi.slash"
        case .failed, .unavailable, .unsupportedSource: return "exclamationmark.circle"
        default: return "info.circle"
        }
    }

    private var aiMasterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeButton(.aiMaster, icon: "wand.and.stars", subtitle: "为每首歌匹配调音，按偏好调整")
            if settings.soundEffectMode == .aiMaster {
                Divider().padding(.horizontal, 12)
                Button {
                    withAnimation(AppAnimation.quick) { showsPreferences.toggle() }
                } label: {
                    HStack {
                        Text("个性偏好")
                        Spacer()
                        Text(preferenceSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: showsPreferences ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sound-effect-preferences")
                .accessibilityValue(showsPreferences ? String(localized: "已展开") : String(localized: "已收起"))
                if showsPreferences { preferences.padding(.horizontal, 12).padding(.bottom, 12) }
            }
        }
        .background(cardBackground(settings.soundEffectMode == .aiMaster))
    }

    private var preferenceSummary: String {
        settings.aiTuningPreferences.isEmpty ? String(localized: "默认")
            : String(localized: "已选 \(settings.aiTuningPreferences.count) 项")
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("调音强度").font(.system(size: 12))
                Slider(value: Binding(get: { settings.aiSoundEffectStrength }, set: player.setAISoundEffectStrength),
                       in: 0...1, step: 0.05)
                    .accessibilityLabel("调音强度")
                Text(settings.aiSoundEffectStrength, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11)).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(AITuningPreference.allCases) { preference in
                    Toggle(preference.title, isOn: Binding(
                        get: { settings.aiTuningPreferences.contains(preference) },
                        set: { player.setAITuningPreference(preference, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox).font(.system(size: 12))
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

    private func modeCard(_ mode: SoundEffectMode, icon: String, subtitle: LocalizedStringKey) -> some View {
        modeButton(mode, icon: icon, subtitle: subtitle)
            .background(cardBackground(settings.soundEffectMode == mode))
    }

    private func modeButton(_ mode: SoundEffectMode, icon: String, subtitle: LocalizedStringKey) -> some View {
        let allowed = signedIn && account.membershipTier >= mode.minimumMembership
        let selected = settings.soundEffectMode == mode
        return Button { player.setSoundEffectMode(mode) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: mode == .aiMaster ? 23 : 18, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : .primary.opacity(0.7))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(mode.title).font(.system(size: 13, weight: .semibold))
                        Text(mode.minimumMembership.displayName)
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : allowed ? "circle" : "lock")
                    .font(.system(size: 16)).foregroundStyle(selected ? Theme.accent : .secondary.opacity(0.6))
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!allowed)
        .accessibilityLabel(mode.title + "，" + mode.minimumMembership.displayName)
        .accessibilityValue(selected ? String(localized: "已选择") : allowed ? String(localized: "可用") : String(localized: "暂无权益"))
    }

    private var presetCatalog: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if !signedIn {
                Text("登录后查看可用音效").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if player.soundEffectPresets.isEmpty {
                Text(player.soundEffectCatalogLoading ? String(localized: "正在加载音效…")
                     : player.soundEffectCatalogFailed ? String(localized: "音效列表加载失败，请重试")
                     : String(localized: "暂无可用音效"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if player.soundEffectCatalogFailed {
                    Text("音效列表更新失败，当前显示已加载的音效")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(player.soundEffectPresets) { preset in presetCard(preset) }
                }
            }
        }
    }

    private func presetCard(_ preset: SoundEffectPreset) -> some View {
        let selected = settings.soundEffectMode == .preset && settings.soundEffectPresetID == preset.id
        let allowed = signedIn && preset.canUse(tier: account.membershipTier)
        return Button { player.selectSoundEffectPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "waveform.path")
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                    Spacer(minLength: 0)
                    if !allowed { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(preset.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                Text(preset.membership == .free ? String(localized: "免费") : preset.membership.displayName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!allowed)
        .background(cardBackground(selected))
        .accessibilityLabel(preset.name + "，" + preset.membership.displayName)
        .accessibilityValue(selected ? String(localized: "已选择") : allowed ? String(localized: "可用") : String(localized: "暂无权益"))
    }

    private func cardBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Theme.accent.opacity(0.055) : .primary.opacity(0.025))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent.opacity(0.55) : .primary.opacity(0.09), lineWidth: 1) }
    }

    private func rememberSelection(_ mode: SoundEffectMode) {
        if mode != .off { lastEnabledMode = mode.rawValue }
    }
}

extension Notification.Name {
    static let showSoundEffectSettings = Notification.Name("Liltiva.showSoundEffectSettings")
}
