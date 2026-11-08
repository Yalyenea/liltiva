import AVKit
import Combine
import SwiftUI

/// System AirPlay / output-route picker (`AVRoutePickerView`), styled to sit
/// among the transport controls. Because playback is audio-only (AVPlayer with
/// no video track), selecting a route sends audio to the device — it does not
/// mirror the screen.
struct RoutePickerButton: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    /// White-on-glass (now-playing) vs. accent-aware (player bar).
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    var body: some View {
        // macOS shows an in-app output-device picker instead of the system
        // one: `AVRoutePickerView` on the Mac routes an `AVPlayer` /
        // `AVSampleBufferAudioRenderer`, and macOS playback is an
        // AVAudioEngine graph with no AVPlayer since the dual-deck engine
        // landed, so that button was inert — selecting an AirPlay speaker did
        // nothing at all. The Mac equivalent is choosing the CoreAudio output
        // device the engine renders to; see `AudioOutputDevices`.
        OutputDevicePicker(
            diameter: diameter, glyphSize: glyphSize, tint: tint, background: background)
    }
}

import AppKit

/// Output routes use the same popup surface and rows as titlebar navigation.
/// A custom panel retains device subtitles and the empty AirPlay explanation.
struct OutputDevicePicker: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    @ObservedObject private var controller = AudioOutputController.shared
    @State private var isPresented = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(controller.isRoutedAway ? Theme.accent : tint)
                .frame(width: diameter, height: diameter)
                .background { chrome }
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .frame(width: diameter, height: diameter)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            OutputDevicePanel(controller: controller) { isPresented = false }
                .popupSurface()
        }
        .controlHint(String(localized: "输出设备"))
        .accessibilityLabel("输出设备")
        .accessibilityValue(controller.currentDisplayName)
    }

    /// Bare in the player bar (hover fill shaped like its `PlayerIconButton`
    /// neighbours), a filled circle on the now-playing glass.
    @ViewBuilder private var chrome: some View {
        let lit = isHovering || isPresented
        if background == .clear {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((colorScheme == .dark ? Color.white : .black).opacity(lit ? 0.08 : 0))
        } else {
            Circle()
                .fill(background)
                .overlay(Circle().fill(Color.white.opacity(lit ? 0.08 : 0)))
        }
    }
}

/// The popover body. Hover and the arrow keys share one highlight, the way a
/// native menu does; Return / Space picks the highlighted row, Esc closes
/// (the popover's own behaviour), and any pick closes it.
private struct OutputDevicePanel: View {
    @ObservedObject var controller: AudioOutputController
    let dismiss: () -> Void

    @State private var highlighted: Row?
    /// Grouped once per device-list change instead of once per body pass:
    /// `sections` dedupes, sorts and runs four filters.
    @State private var sections: [AudioOutputSection] = []

    enum Row: Hashable {
        case systemDefault
        case device(uid: String)
        case soundSettings
    }

    private var selectedRow: Row {
        switch controller.selection {
        case .systemDefault: return .systemDefault
        case .device(let uid): return .device(uid: uid)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("输出设备")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)

            deviceRow(
                .systemDefault,
                title: Text("系统默认"),
                subtitle: controller.systemDefaultName.map { Text(verbatim: $0) }
                    ?? Text("跟随系统设置"),
                symbol: "speaker.wave.2",
                isSelected: controller.selection == .systemDefault)

            ForEach(sections, id: \.group) { section in
                sectionHeader(section.group)
                ForEach(section.devices) { device in
                    deviceRow(
                        .device(uid: device.uid),
                        title: Text(verbatim: device.name),
                        subtitle: device.kind.transportLabel,
                        symbol: device.symbolName,
                        isSelected: controller.selection == .device(uid: device.uid))
                }
                if section.group == .airPlay, section.devices.isEmpty {
                    Text("AirPlay 音箱需先在控制中心或“声音”设置中选择一次，才会出现在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            settingsRow
        }
        .padding(8)
        .frame(width: 290)
        .onReceive(controller.$devices) { sections = AudioOutputDevices.sections($0) }
        .onAppear {
            sections = AudioOutputDevices.sections(controller.devices)
            controller.refresh()
        }
        .popupKeyboardNavigation(items: rows(in: sections), selection: selectedRow,
                                 highlighted: $highlighted, onSelect: pick, onDismiss: dismiss)
    }

    // MARK: Rows

    private func sectionHeader(_ group: AudioOutputGroup) -> some View {
        Text(group.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func deviceRow(
        _ row: Row, title: Text, subtitle: Text?, symbol: String, isSelected: Bool
    ) -> some View {
        PopupRow(isSelected: isSelected, isHighlighted: highlighted == row,
                 onHover: { if $0 { highlighted = row } },
                 action: { pick(row) }) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let subtitle {
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
        }
    }

    private var settingsRow: some View {
        PopupRow(isHighlighted: highlighted == .soundSettings,
                 onHover: { if $0 { highlighted = .soundSettings } },
                 action: { pick(.soundSettings) }) {
            HStack {
                Text("声音设置…")
                    .font(.system(size: 13))
                Spacer()
            }
        }
        .accessibilityHint("打开系统设置中的“声音”")
    }

    // MARK: Interaction

    private func rows(in sections: [AudioOutputSection]) -> [Row] {
        [.systemDefault]
            + sections.flatMap { $0.devices.map { Row.device(uid: $0.uid) } }
            + [.soundSettings]
    }

    private func pick(_ row: Row) {
        dismiss()
        switch row {
        case .systemDefault:
            select(.systemDefault)
        case .device(let uid):
            select(.device(uid: uid))
        case .soundSettings:
            SoundSettings.open()
        }
    }

    /// Re-picking the current row is a no-op here: `select` always re-points
    /// the engine, which is an audible rebuild for nothing.
    private func select(_ selection: AudioOutputSelection) {
        guard selection != controller.selection else { return }
        controller.select(selection)
    }
}

private extension AudioOutputGroup {
    var title: LocalizedStringKey {
        switch self {
        case .thisMac: return "此 Mac"
        case .external: return "外接设备"
        case .virtual: return "虚拟设备"
        case .airPlay: return "AirPlay"
        }
    }
}

private extension AudioOutputKind {
    /// The picker's secondary line — the "类型" column of System Settings ›
    /// Sound, for the sections whose header does not already say it.
    var transportLabel: Text? {
        switch self {
        case .bluetooth: return Text("蓝牙")
        case .usb: return Text(verbatim: "USB")
        case .hdmi: return Text(verbatim: "HDMI")
        case .displayPort: return Text(verbatim: "DisplayPort")
        case .thunderbolt: return Text(verbatim: "Thunderbolt")
        case .virtual: return Text("虚拟")
        case .aggregate: return Text("聚合")
        case .builtInSpeakers, .builtInHeadphones, .airPlay, .other: return nil
        }
    }
}

/// System Settings › Sound. The extension ID is what the Sound pane
/// registers on macOS 13+ (`/System/Library/ExtensionKit/Extensions/
/// Sound.appex`, `CFBundleIdentifier` = `com.apple.Sound-Settings.extension`);
/// the legacy prefPane ID is kept as a fallback, then System Settings itself.
@MainActor
enum SoundSettings {
    static let urls = [
        "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.sound",
    ]

    static func open() {
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
