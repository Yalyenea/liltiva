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
            SettingsPopUpButton(title: NSLocalizedString(title, comment: ""), selection: $selection, options: options)
                .frame(width: width, height: 22)
        }
    }
}

/// A native popup keeps the actual bezel at the requested width. SwiftUI's
/// macOS menu styles shrink their bezel to the label even inside a fixed frame.
private struct SettingsPopUpButton<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 13)
        button.bezelStyle = .rounded
        button.contentTintColor = NSColor(Theme.accent)
        button.autoenablesItems = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectOption(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let previous = context.coordinator.parent.options
        context.coordinator.parent = self
        // Rebuilding a tracking menu on unrelated player updates disrupts input.
        if previous != options || button.numberOfItems != options.count {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
                button.lastItem?.isEnabled = option.isEnabled
            }
        }
        button.selectItem(at: options.firstIndex(where: { $0.value == selection }) ?? -1)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 128, height: 22)
    }

    final class Coordinator: NSObject {
        var parent: SettingsPopUpButton
        init(_ parent: SettingsPopUpButton) { self.parent = parent }
        @objc func selectOption(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard parent.options.indices.contains(index), parent.options[index].isEnabled else { return }
            parent.selection = parent.options[index].value
        }
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
