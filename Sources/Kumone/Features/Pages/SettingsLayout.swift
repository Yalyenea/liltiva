import SwiftUI

/// Shared spacing keeps every settings page on the same quiet, flat surface.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28, content: content)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .toggleStyle(SettingsToggleStyle())
        .labeledContentStyle(SettingsValueStyle())
    }
}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.accessibilityHidden(true)
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { configuration.label }.labelsHidden().toggleStyle(.switch)
        }
    }
}

private struct SettingsValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

struct SettingsPickerOption<Value: Hashable>: Equatable {
    let value: Value
    let title: String
    var isEnabled = true
    var symbol: String? = nil
}

struct SettingsPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]
    let width: CGFloat

    init(_ title: String, selection: Binding<Value>, width: CGFloat = 128, options: [SettingsPickerOption<Value>]) {
        self.title = title
        _selection = selection
        self.width = width
        self.options = options
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(LocalizedStringKey(title))
            Spacer(minLength: 12)
            SettingsChoiceButton(title: NSLocalizedString(title, comment: ""), selection: $selection,
                                 options: options, width: width)
        }
    }
}

/// Settings values and the compact category header share the same popup.
struct SettingsChoiceButton<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]
    var width: CGFloat = 128
    @State private var isPresented = false
    @State private var highlighted: Value?
    @FocusState private var isFocused: Bool

    private var selectedOption: SettingsPickerOption<Value>? {
        options.first { $0.value == selection }
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if let symbol = selectedOption?.symbol {
                    Image(systemName: symbol).foregroundStyle(Theme.accent)
                }
                Text(selectedOption?.title ?? "")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(width: width, height: 22)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .accessibilityLabel(title)
        .accessibilityValue(selectedOption?.title ?? "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.value) { option in
                    PopupRow(isSelected: option.value == selection,
                             isHighlighted: highlighted == option.value,
                             onHover: { if $0 && option.isEnabled { highlighted = option.value } },
                             action: { select(option) }) {
                        HStack(spacing: 10) {
                            if let symbol = option.symbol {
                                Image(systemName: symbol)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18)
                            }
                            Text(option.title)
                            Spacer(minLength: 0)
                        }
                    }
                    .disabled(!option.isEnabled)
                }
            }
            .padding(8)
            .frame(width: max(200, width))
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .defaultFocus($isFocused, true)
            .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
            .onKeyPress(.return) { activateHighlight(); return .handled }
            .onKeyPress(.space) { activateHighlight(); return .handled }
            .onExitCommand { isPresented = false }
            .onAppear {
                highlighted = options.first { $0.value == selection && $0.isEnabled }?.value
                    ?? options.first { $0.isEnabled }?.value
                isFocused = true
            }
            .popupSurface()
        }
    }

    private func select(_ option: SettingsPickerOption<Value>) {
        guard option.isEnabled else { return }
        selection = option.value
        isPresented = false
    }

    private func activateHighlight() {
        guard let option = options.first(where: { $0.value == highlighted }) else { return }
        select(option)
    }

    private func moveHighlight(by offset: Int) {
        // Skip unavailable choices so keyboard selection matches mouse input.
        let enabled = options.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex { $0.value == highlighted } ?? (offset > 0 ? -1 : enabled.count)
        let next = min(max(current + offset, 0), enabled.count - 1)
        highlighted = enabled[next].value
    }
}

struct SettingsSection<Content: View, Footer: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Divider()
            }
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
            footer()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}
