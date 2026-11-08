import SwiftUI

/// Keep selection and hover identical to the titlebar's navigation popup.
struct PopupRowBackground: View {
    var isSelected = false
    var isHighlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(.primary.opacity(isSelected ? 0.1 : (isHighlighted ? 0.06 : 0)))
    }
}

struct PopupRow<Content: View>: View {
    var isSelected = false
    var isHighlighted = false
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(PopupRowBackground(
                    isSelected: isSelected,
                    isHighlighted: isEnabled && (isHovering || isHighlighted)))
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover {
            isHovering = $0
            onHover($0)
        }
    }
}

extension View {
    func popupSurface() -> some View {
        modifier(PopupSurface())
    }

    func popupKeyboardNavigation<Item: Hashable>(
        items: [Item], selection: Item? = nil, highlighted: Binding<Item?>,
        onSelect: @escaping (Item) -> Void, onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(PopupKeyboardNavigation(items: items, selection: selection,
                                         highlighted: highlighted,
                                         onSelect: onSelect, onDismiss: onDismiss))
    }
}

@MainActor
enum PopupPresentation {
    static var activeIDs: Set<UUID> = []
    static var isPresented: Bool { !activeIDs.isEmpty }

}

private struct PopupSurface: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        // Set the presentation itself so its rim is opaque too. Popup input
        // must reach its controls before app-wide playback shortcuts.
        content
            .presentationBackground(Platform.windowBackgroundColor)
            .tint(Theme.accent)
            .noFocusRing()
            .onAppear { PopupPresentation.activeIDs.insert(id) }
            .onDisappear { PopupPresentation.activeIDs.remove(id) }
    }
}

private struct PopupKeyboardNavigation<Item: Hashable>: ViewModifier {
    let items: [Item]
    let selection: Item?
    @Binding var highlighted: Item?
    let onSelect: (Item) -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .defaultFocus($isFocused, true)
            .onAppear {
                highlighted = nil
                isFocused = true
            }
            .onKeyPress(.upArrow) { move(by: -1); return .handled }
            .onKeyPress(.downArrow) { move(by: 1); return .handled }
            .onKeyPress(.return) { activate() }
            .onKeyPress(.space) { activate() }
            .onExitCommand(perform: onDismiss)
    }

    private func move(by step: Int) {
        guard !items.isEmpty else { return }
        guard let current = highlighted, let index = items.firstIndex(of: current) else {
            highlighted = selection.flatMap { items.contains($0) ? $0 : nil }
                ?? (step > 0 ? items.first : items.last)
            return
        }
        highlighted = items[min(max(index + step, 0), items.count - 1)]
    }

    private func activate() -> KeyPress.Result {
        guard let item = highlighted ?? selection, items.contains(item) else { return .ignored }
        onSelect(item)
        return .handled
    }
}
