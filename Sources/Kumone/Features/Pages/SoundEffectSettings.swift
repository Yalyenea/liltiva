import SwiftUI

struct SoundEffectSettings: View {
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var account = AccountStore.shared

    var body: some View {
        SettingsSection("音效") {
            SettingsPicker("音效模式", selection: Binding(get: { settings.soundEffectMode }, set: player.setSoundEffectMode), width: 184,
                           options: SoundEffectMode.allCases.map {
                .init(value: $0, title: $0.title + membershipSuffix($0.minimumMembership),
                      isEnabled: $0.minimumMembership <= account.membershipTier)
            })
            // Choosing a preset activates it directly; no mode change is required first.
            SettingsPicker("预设音效", selection: Binding<Int?>(
                get: {
                    guard settings.soundEffectMode == .preset else { return nil }
                    return player.soundEffectPresets.first(where: { $0.id == settings.soundEffectPresetID })?.id
                },
                set: { id in
                    guard let preset = player.soundEffectPresets.first(where: { $0.id == id }) else { return }
                    player.selectSoundEffectPreset(preset)
                }
            ), width: 184, options: [
                .init(value: nil, title: String(localized: "选择音效"), isEnabled: false)
            ] + player.soundEffectPresets.map {
                .init(value: $0.id, title: $0.name + membershipSuffix($0.membership),
                      isEnabled: $0.canUse(tier: account.membershipTier))
            })
            .disabled(player.soundEffectPresets.isEmpty)
            if account.authenticatedAccountID == nil {
                Text("登录后可使用音效").foregroundStyle(.secondary)
            } else if player.soundEffectCatalogLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载音效…").foregroundStyle(.secondary)
                }
            } else if player.soundEffectCatalogFailed {
                Button("重新加载音效列表") { player.loadSoundEffectCatalog(refresh: true) }
            }
            if settings.soundEffectMode != .off {
                LabeledContent("音效状态", value: player.soundEffectState.displayName)
                if let labels = player.soundEffectEmotionLabel, !labels.isEmpty {
                    LabeledContent("歌曲情绪", value: labels)
                }
                if [.failed, .offlineMissing, .unauthorized].contains(player.soundEffectState) {
                    Button("重试音效") { player.refreshSoundEffect(retry: true) }
                }
            }
        } footer: {
            if settings.soundEffectMode == .emotion { Text("使用官方歌曲分析数据，由 Liltiva 本地调音。") }
            else if settings.soundEffectMode != .off { Text("采用官方参数，本地处理的听感与网易云音乐可能有差异。") }
        }
        .onAppear { player.loadSoundEffectCatalog() }

        if settings.soundEffectMode == .aiMaster {
            SettingsSection("个性偏好") {
                HStack(spacing: 12) {
                    Text("调音强度")
                    Spacer(minLength: 12)
                    Slider(value: Binding(get: { settings.aiSoundEffectStrength }, set: player.setAISoundEffectStrength),
                           in: 0...1, step: 0.05)
                        .frame(maxWidth: 180)
                        .accessibilityLabel("调音强度")
                    Text(settings.aiSoundEffectStrength, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                ForEach(AITuningPreference.allCases) { preference in
                    Toggle(isOn: Binding(get: { settings.aiTuningPreferences.contains(preference) },
                                         set: { player.setAITuningPreference(preference, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preference.title)
                            if let reason = player.closedTuningPreferences[preference] {
                                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("重置偏好") { player.resetAITuningPreferences() }
                    .disabled(settings.aiTuningPreferences.isEmpty && settings.aiSoundEffectStrength == 1)
            }
        }
    }

    private func membershipSuffix(_ tier: MusicMembershipTier) -> String {
        tier == .free ? "" : " · " + tier.displayName
    }
}

struct SoundEffectPresetOptions: View {
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var account = AccountStore.shared
    var body: some View {
        if account.authenticatedAccountID == nil {
            Text("登录后可使用音效")
        } else if player.soundEffectCatalogLoading && player.soundEffectPresets.isEmpty {
            Text("正在加载音效…")
        } else if player.soundEffectCatalogFailed {
            Button("重新加载音效列表") { player.loadSoundEffectCatalog(refresh: true) }
        } else if player.soundEffectPresets.isEmpty {
            Text("暂无可用音效")
        }
        Picker("预设音效", selection: Binding<Int?>(
            get: { settings.soundEffectMode == .preset ? settings.soundEffectPresetID : nil },
            set: { id in
                guard let preset = player.soundEffectPresets.first(where: { $0.id == id }) else { return }
                player.selectSoundEffectPreset(preset)
            }
        )) {
            ForEach(player.soundEffectPresets) { preset in
                Text(preset.name + (preset.membership == .free ? "" : " · " + preset.membership.displayName))
                    .tag(Optional(preset.id))
                    .disabled(!preset.canUse(tier: account.membershipTier))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

struct SoundEffectMenu: View {
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        // A Picker sets the native menu item's checked state; a Label image does not.
        Picker("音效模式", selection: Binding(get: { settings.soundEffectMode }, set: player.setSoundEffectMode)) {
            ForEach(SoundEffectMode.allCases) { mode in
                let title = mode == .preset
                    ? (player.soundEffectPresets.first(where: { $0.id == settings.soundEffectPresetID })?.name ?? mode.title)
                    : mode.title
                Text(title + (mode.minimumMembership == .free ? "" : " · " + mode.minimumMembership.displayName))
                    .tag(mode)
                    .disabled(mode.minimumMembership > account.membershipTier)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Menu("音效列表") { SoundEffectPresetOptions() }
        if settings.soundEffectMode != .off { Text(player.soundEffectState.displayName) }
        Divider()
        Button("音效设置…") {
            openSettings()
            NotificationCenter.default.post(name: .showSoundEffectSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let showSoundEffectSettings = Notification.Name("Liltiva.showSoundEffectSettings")
}
