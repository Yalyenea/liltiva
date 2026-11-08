import SwiftUI

/// Cards that scale up on hover, scale down on press, with a soft shadow.
struct InteractiveCardStyle: ButtonStyle {
    var showShadow = true
    var hoverScale: CGFloat = 1.02
    var pressScale: CGFloat = 0.98

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : (isHovering ? hoverScale : 1.0))
            .shadow(
                color: showShadow && isHovering ? .black.opacity(0.15) : .clear,
                radius: isHovering ? 12 : 0,
                x: 0,
                y: isHovering ? 4 : 0
            )
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }
}

/// List rows with a hover background highlight.
struct InteractiveRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Radius.standard
    var hoverColor: Color = .primary.opacity(0.06)

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovering)
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }
}

/// Subtle press feedback for icon buttons.
struct PressableButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .focusEffectDisabled()
    }
}

/// Filter chips (category pickers).
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(.primary.opacity(isHovering ? 0.1 : 0.06))
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovering ? 1.03 : 1.0))
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }
}

extension ButtonStyle where Self == InteractiveCardStyle {
    static var interactiveCard: InteractiveCardStyle { InteractiveCardStyle() }
}

extension ButtonStyle where Self == InteractiveRowStyle {
    static var interactiveRow: InteractiveRowStyle { InteractiveRowStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static func chip(isSelected: Bool) -> ChipButtonStyle { ChipButtonStyle(isSelected: isSelected) }
}

/// Render short control hints in the app so their visibility does not depend
/// on the system tooltip delay or native button hosting.
private struct ControlHintModifier: ViewModifier {
    let text: String
    let isPresented: Bool?
    @State private var isHovering = false

    private var isVisible: Bool { isPresented ?? isHovering }

    func body(content: Content) -> some View {
        content
            .onHover { if isPresented == nil { isHovering = $0 } }
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .panelSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                        .fixedSize()
                        // Leave room for the progress lane above the controls.
                        .offset(y: -50)
                        // The hint must not steal hover from its button.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(AppAnimation.quick, value: isVisible)
    }
}

extension View {
    func controlHint(_ text: String, isPresented: Bool? = nil) -> some View {
        modifier(ControlHintModifier(text: text, isPresented: isPresented))
    }
}
