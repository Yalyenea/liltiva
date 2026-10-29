import SwiftUI

@MainActor
struct StorageSpaceView: View {
    let onManageDownloads: () -> Void
    @StateObject private var model = StorageSpaceModel()
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsForm {
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    if let capacity = model.snapshot?.device {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(deviceName).font(.headline)
                                Spacer()
                                capacityText(capacity)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(deviceName).font(.headline)
                                capacityText(capacity)
                            }
                        }
                        StorageCapacityBar(capacity: capacity, appBytes: model.snapshot?.appBytes ?? 0)
                    } else if model.isLoading {
                        HStack { ProgressView(); Text("正在计算存储空间…").foregroundStyle(.secondary) }
                    } else {
                        Text("暂时无法读取设备容量").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            SettingsSection {
                LabeledContent(model.snapshot?.partial == true ? String(localized: "已统计的 Liltiva 占用") : String(localized: "Liltiva 占用")) {
                    Text(model.snapshot.map { format($0.appBytes) } ?? "—")
                        .font(.body.weight(.semibold)).monospacedDigit()
                }
            }

            SettingsSection {
                usageRow("图片缓存", icon: "photo.on.rectangle", category: .imageCache)
                Button(role: .destructive) { Task { await model.clear(.imageCache) } } label: {
                    HStack {
                        Text("清除图片缓存")
                        if model.clearingCategory == .imageCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.imageCache] ?? 0) == 0)
            } footer: {
                Text("清除后保留已下载歌曲的封面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsSection {
                usageRow("歌曲缓存", icon: "music.note", category: .musicCache)
                SettingsPicker("上限", selection: $settings.audioCacheLimit, options: [
                    .init(value: Int64(512) << 20, title: "512 MB"),
                    .init(value: Int64(2) << 30, title: "2 GB"),
                    .init(value: Int64(8) << 30, title: "8 GB"),
                    .init(value: Int64(0), title: String(localized: "不限")),
                ])
                Button(role: .destructive) { Task { await model.clear(.musicCache) } } label: {
                    HStack {
                        Text("清除歌曲缓存")
                        if model.clearingCategory == .musicCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.musicCache] ?? 0) == 0)
            } footer: {
                Text("暂存最近播放的歌曲，不含已下载音乐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsSection {
                Button(action: onManageDownloads) {
                    HStack {
                        Label("已下载", systemImage: "arrow.down.circle")
                        Spacer()
                        Text(size(.downloads)).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                if let other = model.snapshot?.otherAccountDownloads, other > 0 {
                    Text("其他账号的下载占用 \(format(other))。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection {
                usageRow("应用数据", icon: "internaldrive", category: .appData)
            } footer: {
                Text("应用、歌词、离线封面与账号资料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = model.message ?? (model.snapshot?.partial == true ? String(localized: "部分存储信息不可用") : nil) {
                SettingsSection { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active, !model.isClearing {
                await model.reload()
            }
        }
        .onChange(of: settings.audioCacheLimit) { _, _ in
            Task { await model.reload() }
        }
    }

    private var busy: Bool { model.isLoading || model.isClearing }
    private var deviceName: String {
        return "Mac"
    }
    private func size(_ category: StorageCategory) -> String {
        guard let snapshot = model.snapshot, !snapshot.unavailableCategories.contains(category) else { return "—" }
        return format(snapshot[category])
    }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func capacityText(_ capacity: DeviceStorageCapacity) -> some View {
        Text("已用 \(format(capacity.used))，共 \(format(capacity.total))")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }
    private func usageRow(_ title: LocalizedStringKey, icon: String, category: StorageCategory) -> some View {
        LabeledContent {
            Text(size(category)).monospacedDigit().foregroundStyle(.secondary)
        } label: { Label(title, systemImage: icon) }
    }
}
