import SwiftUI

// MARK: - Skeletons

struct SkeletonView: View {
    var cornerRadius: CGFloat = Theme.Radius.standard

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .primary.opacity(0.08), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: (geo.size.width * 1.6) * phase - geo.size.width * 0.6)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct SkeletonCardView: View {
    var size: CGFloat = Theme.Layout.cardSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonView().frame(width: size, height: size)
            SkeletonView(cornerRadius: 4).frame(width: size * 0.8, height: 12)
            SkeletonView(cornerRadius: 4).frame(width: size * 0.5, height: 10)
        }
    }
}

struct SkeletonShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonView(cornerRadius: 4).frame(width: 120, height: 20)
            GeometryReader { geometry in
                let cardSize = Theme.Layout.fittedShelfCardSize(availableWidth: geometry.size.width, leadingInset: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonCardView(size: cardSize)
                        }
                    }
                }
            }
            .frame(height: Theme.Layout.coverShelfHeight)
        }
    }
}

// MARK: - Staggered entrance

private enum AnimationCache {
    nonisolated(unsafe) static var animated = Set<String>()

    static func hasAnimated(_ key: String) -> Bool { animated.contains(key) }

    static func markAnimated(_ key: String) {
        if animated.count > 600 { animated.removeAll() }
        animated.insert(key)
    }
}

struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    var itemID: String

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 16)
            .onAppear {
                if Platform.isReduceMotionEnabled
                    || AnimationCache.hasAnimated(itemID) {
                    isVisible = true
                    return
                }
                withAnimation(AppAnimation.snappy.delay(AppAnimation.stagger(for: index))) {
                    isVisible = true
                }
                AnimationCache.markAnimated(itemID)
            }
    }
}

extension View {
    func staggeredAppearance(index: Int, id: String) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, itemID: id))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .offset(x: isHovering ? 2 : 0)
                    }
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .onHover { hovering in
                    withAnimation(AppAnimation.quick) { isHovering = hovering }
                }
            } else {
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Badges

struct PlayCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            Text(Formatters.playCount(count))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(.black.opacity(0.35), in: Capsule())
        .background(Platform.windowBackgroundColor, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }
}

struct VIPBadge: View {
    var body: some View {
        Text("VIP")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.accent.opacity(0.8), lineWidth: 1)
            )
    }
}

struct QualityTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1)
            )
    }
}

// MARK: - Hover play overlay

struct PlayOverlayButton: View {
    var visible: Bool
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(0.92), in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.7)
        .animation(AppAnimation.spring, value: visible)
        // Opacity alone leaves it clickable while invisible.
        .allowsHitTesting(visible)
    }
}

// MARK: - Marquee

/// Scrolls text horizontally when it overflows, with faded edges.
///
/// Driven by Core Animation rather than SwiftUI. This view sits permanently in
/// the player bar, and a `repeatForever` SwiftUI animation keeps the entire view
/// graph re-rendering for as long as it runs — measured at ~15% of a core, for
/// as long as the current title happened to be long enough to scroll. A
/// `CABasicAnimation` is handed to the render server once and then costs this
/// process nothing.
struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 13
    var fontWeight: PlatformFont.Weight = .medium

    var body: some View {
        MarqueeTextView.Representable(text: text, fontSize: fontSize, weight: fontWeight)
    }
}

final class MarqueeTextView: PlatformView {
    /// Gap between the two copies of the text.
    private static let gap: CGFloat = 32
    /// Points per second.
    private static let speed: CGFloat = 24
    /// Pause before a new title starts travelling, so it can be read first.
    private static let leadIn: CFTimeInterval = 1.6
    private static let fadeFraction = 0.06

    private let scroller = NSView()
    // Let AppKit rasterize labels at the display's backing scale. Bare text
    // layers lose that automatic management and soften small player titles.
    private let first = NSTextField(labelWithString: "")
    private let second = NSTextField(labelWithString: "")
    private let fade = CAGradientLayer()

    private var text: String
    private var fontSize: CGFloat
    private var weight: PlatformFont.Weight
    private var textWidth: CGFloat = 0
    /// Guards against re-running layout on every display cycle: the host view
    /// calls layout() each frame while an animation is in flight, and tearing
    /// the animation down and rebuilding it there costs more than the SwiftUI
    /// version ever did.
    private var laidOutFor: CGSize = .zero
    private var needsMarquee: Bool { textWidth > bounds.width + 1 }

    /// Access the backing layer after enabling layer-backed rendering.
    private var hostLayer: CALayer? { layer }

    init(text: String, fontSize: CGFloat, weight: PlatformFont.Weight, foregroundColor: CGColor) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        super.init(frame: .zero)
        wantsLayer = true
        scroller.wantsLayer = true
        addSubview(scroller)
        scroller.addSubview(first)
        scroller.addSubview(second)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        for label in [first, second] {
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
        }
        second.setAccessibilityElement(false)
        applyForegroundColor(foregroundColor)
        applyText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, fontSize: CGFloat, weight: PlatformFont.Weight, foregroundColor: CGColor) {
        // Theme changes must reach both copies even when the title is unchanged.
        applyForegroundColor(foregroundColor)
        guard text != self.text || fontSize != self.fontSize || weight != self.weight else { return }
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        applyText()
        relayout()
    }

    private var font: PlatformFont { .systemFont(ofSize: fontSize, weight: weight) }

    private func applyForegroundColor(_ color: CGColor) {
        let color = NSColor(cgColor: color)
        guard first.textColor != color else { return }
        first.textColor = color
        second.textColor = color
    }

    private func applyText() {
        let font = self.font
        for label in [first, second] {
            label.stringValue = text
            label.font = font
        }
        textWidth = ceil(first.intrinsicContentSize.width)
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutFor else { return }
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    private func relayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        laidOutFor = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let lineHeight = ceil(first.intrinsicContentSize.height)
        let labelFrame = backingAlignedRect(
            CGRect(x: 0, y: (bounds.height - lineHeight) / 2,
                   width: textWidth, height: lineHeight), options: .alignAllEdgesNearest)
        let y = labelFrame.origin.y
        first.frame = labelFrame
        second.frame = CGRect(x: textWidth + Self.gap, y: y, width: textWidth, height: lineHeight)
        second.isHidden = !needsMarquee
        scroller.frame = CGRect(x: 0, y: 0,
                                width: textWidth * 2 + Self.gap, height: bounds.height)
        // Short titles need neither an offscreen mask nor a scrolling surface.
        hostLayer?.mask = needsMarquee ? fade : nil
        fade.frame = bounds
        fade.contentsScale = window?.backingScaleFactor ?? 1
        fade.colors = fadeColors()
        fade.locations = fadeLocations()

        CATransaction.commit()
        restartAnimation()
    }

    private func fadeColors() -> [CGColor] {
        let opaque = PlatformColor.black.cgColor
        let clear = PlatformColor.black.withAlphaComponent(0).cgColor
        guard needsMarquee else { return [opaque, opaque, opaque, opaque] }
        return [clear, opaque, opaque, clear]
    }

    private func fadeLocations() -> [NSNumber] {
        guard needsMarquee else { return [0, 0, 1, 1] }
        return [0, NSNumber(value: Self.fadeFraction),
                NSNumber(value: 1 - Self.fadeFraction), 1]
    }

    private func restartAnimation() {
        scroller.layer?.removeAnimation(forKey: "marquee")
        guard needsMarquee, !Platform.isReduceMotionEnabled else { return }

        let distance = textWidth + Self.gap
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.byValue = -distance
        animation.duration = CFTimeInterval(distance / Self.speed)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = CACurrentMediaTime() + Self.leadIn
        scroller.layer?.add(animation, forKey: "marquee")
    }

    // MARK: Bridge

    struct Representable: PlatformViewRepresentable {
        let text: String
        let fontSize: CGFloat
        let weight: PlatformFont.Weight

        func makeNSView(context: Context) -> MarqueeTextView {
            // The player can use a dark SwiftUI theme inside a light AppKit
            // window. Resolve here so the layer follows that local theme.
            MarqueeTextView(text: text, fontSize: fontSize, weight: weight,
                            foregroundColor: Color.primary.resolve(in: context.environment).cgColor)
        }
        func updateNSView(_ view: MarqueeTextView, context: Context) {
            view.update(text: text, fontSize: fontSize, weight: weight,
                        foregroundColor: Color.primary.resolve(in: context.environment).cgColor)
        }
    }
}
