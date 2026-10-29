import QuartzCore
import SwiftUI

/// A small ivory pivot and bent aluminium arm, with the needle resting on
/// the record's grooves, moving inward as the song progresses.
public struct VinylTonearmView: View {
    public let isPlaying: Bool
    public let duration: TimeInterval
    public let height: CGFloat
    public let reduceMotion: Bool
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared
    // Keep clock updates local to the arm instead of rebuilding the record or page.
    @ObservedObject private var clock = PlayerService.shared.clock

    public init(isPlaying: Bool, duration: TimeInterval = 0,
                height: CGFloat = 175, reduceMotion: Bool = false) {
        self.isPlaying = isPlaying
        self.duration = duration
        self.height = height
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let width = height * 0.58
        let pivotSize = width * 0.24

        ZStack(alignment: .top) {
            pivotBase(size: pivotSize)
                .zIndex(3)
            EngagingTonearm(
                arm: armAssembly(width: width, height: height),
                engaged: isPlaying,
                progress: duration > 0 ? clock.progress / duration : 0,
                wobbling: isPlaying && !reduceMotion && windowVisibility.isVisible,
                animated: !reduceMotion,
                width: width,
                height: height,
                pivotY: pivotSize * 0.5
            )
            .shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 4)
            .zIndex(2)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    static func wobbleDegrees(at seconds: Double) -> Double {
        let harmonic1 = sin(seconds * 2.0 * .pi / 3.2) * 0.20
        let harmonic2 = sin(seconds * 2.0 * .pi / 1.1 + 0.6) * 0.08
        return harmonic1 + harmonic2
    }

    private func pivotBase(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.18))
                .frame(width: size * 1.35, height: size * 1.35)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.7) }
            Circle()
                .fill(Color(white: 0.8))
                .frame(width: size * 0.37, height: size * 0.37)
                .overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }

    private func armAssembly(width: CGFloat, height: CGFloat) -> some View {
        let tubeWidth = max(2, width * 0.045)
        return ZStack(alignment: .top) {
            TonearmPath()
                .stroke(Color(white: 0.45),
                        style: StrokeStyle(lineWidth: tubeWidth + 1, lineCap: .round, lineJoin: .round))
            TonearmPath()
                .stroke(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.76), Color(white: 0.94)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: tubeWidth, lineCap: .round, lineJoin: .round))
            headshell(width: width, height: height)
        }
        .frame(width: width, height: height)
        // Both the shape and the layer share this pivot; changing the size
        // must not shift the hinge during the play/pause swing.
        .offset(y: width * 0.24 * 0.5)
    }

    private func headshell(width: CGFloat, height: CGFloat) -> some View {
        let headWidth = width * 0.115
        let headHeight = height * 0.15
        return ZStack {
            RoundedRectangle(cornerRadius: headWidth * 0.15)
                .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.72), Color(white: 0.9)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay {
                    RoundedRectangle(cornerRadius: headWidth * 0.15)
                        .strokeBorder(.white.opacity(0.7), lineWidth: 0.6)
                }
            Rectangle()
                .fill(Color(white: 0.4))
                .frame(width: headWidth * 0.65, height: max(1, height * 0.008))
                .offset(y: headHeight * 0.35)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: max(1, headWidth * 0.12), height: headHeight * 0.65)
                .offset(x: headWidth * 0.7, y: -headHeight * 0.22)
        }
        .frame(width: headWidth, height: headHeight)
        .rotationEffect(.degrees(-39))
        .position(x: width * 0.90, y: height * 0.70)
    }
}

private struct TonearmPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.5, y: 0))
        path.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.30))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.61, y: rect.height * 0.46),
            control: CGPoint(x: rect.width * 0.53, y: rect.height * 0.40)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.70))
        return path
    }
}

// MARK: - Arm motion on the layer

/// Drives the arm's layer: a spring for the engage/disengage swing, and an
/// additive keyframe wobble while the record plays. The `TimelineView` this
/// replaces re-evaluated the whole arm — and the page's layout around it —
/// on every display frame for that ±0.28° shimmer (#128 performance work).
final class TonearmMotionController {
    private static let parkedDegrees: Double = -32

    private let layer: CALayer
    private var rotation: Double
    private var wobbling = false

    init(layer: CALayer, engaged: Bool, progress: Double) {
        self.layer = layer
        rotation = Self.zRotation(engaged: engaged, progress: progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(rotation, forKeyPath: "sublayerTransform.rotation.z")
        CATransaction.commit()
    }

    func setEngaged(_ engaged: Bool, progress: Double, animated: Bool) {
        let target = Self.zRotation(engaged: engaged, progress: progress)
        guard target != rotation else { return }
        rotation = target
        // Retarget from what is on screen, not from the model: a drag released
        // mid-swing must reverse smoothly rather than jump to the far end.
        let from = layer.presentation()?.value(forKeyPath: "sublayerTransform.rotation.z") as? Double
            ?? layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: "sublayerTransform.rotation.z")
        CATransaction.commit()
        layer.removeAnimation(forKey: "tonearm-engage")
        guard animated else { return }
        // CASpringAnimation parameters converted from the SwiftUI spring this
        // replaces (response 0.48, damping fraction 0.74, mass 1).
        let spring = CASpringAnimation(keyPath: "sublayerTransform.rotation.z")
        spring.mass = 1
        spring.stiffness = 171.5
        spring.damping = 19.4
        spring.initialVelocity = 0
        spring.fromValue = from
        spring.toValue = target
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "tonearm-engage")
    }

    func setWobbling(_ wobbling: Bool) {
        guard wobbling != self.wobbling else { return }
        self.wobbling = wobbling
        guard wobbling else {
            layer.removeAnimation(forKey: "tonearm-wobble")
            return
        }
        // One seamless period of `wobbleDegrees`, sampled. Additive: the
        // shimmer rides on the resting angle the spring sets instead of
        // replacing it.
        let period = 35.2
        let step = 0.1
        let samples = Int(period / step) + 1
        let values = (0..<samples).map { index in
            -VinylTonearmView.wobbleDegrees(at: Double(index) * step) * .pi / 180
        }
        let animation = CAKeyframeAnimation(keyPath: "sublayerTransform.rotation.z")
        animation.values = values
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isAdditive = true
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "tonearm-wobble")
    }

    /// Core Animation measures angles the other way round from SwiftUI, so the
    /// SwiftUI-side degrees (`-32` parks the arm away from the record) arrive
    /// on the layer negated.
    private static func zRotation(engaged: Bool, progress: Double) -> Double {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        guard engaged else { return -parkedDegrees * .pi / 180 }

        // Advance across the groove radius, rather than interpolating angles:
        // half a track should put the stylus halfway across the playable band.
        // Coordinates are normalized by disc diameter and follow the turntable,
        // arm path and the lower contact point of the headshell above.
        let armHeight = 0.56
        let armWidth = armHeight * 0.58
        let headAngle = 39.0 * .pi / 180
        let contactOffset = armHeight * 0.15 * 0.35
        let tipX = armWidth * 0.40 + contactOffset * sin(headAngle)
        let tipY = armHeight * 0.70 + contactOffset * cos(headAngle)
        let centerX = -0.03
        let centerY = 0.72 - armWidth * 0.12
        let armLength = hypot(tipX, tipY)
        let centerDistance = hypot(centerX, centerY)
        // Leave a little clearance inside the rim and outside the label.
        let radius = 0.48 + (0.325 - 0.48) * fraction
        let cosine = (armLength * armLength + centerDistance * centerDistance - radius * radius)
            / (2 * armLength * centerDistance)
        let angle = atan2(centerY, centerX) - atan2(tipY, tipX) - acos(cosine)
        return -angle
    }
}

private struct EngagingTonearm<Content: View>: PlatformViewRepresentable {
    let arm: Content
    let engaged: Bool
    let progress: Double
    let wobbling: Bool
    let animated: Bool
    let width: CGFloat
    let height: CGFloat
    let pivotY: CGFloat

    func makeNSView(context: Context) -> TonearmHost<Content> {
        TonearmHost(arm: arm, engaged: engaged, progress: progress, wobbling: wobbling,
                    width: width, height: height, pivotY: pivotY)
    }

    func updateNSView(_ host: TonearmHost<Content>, context: Context) {
        host.update(arm: arm, width: width, height: height, pivotY: pivotY)
        host.motion.setEngaged(engaged, progress: progress, animated: animated)
        host.motion.setWobbling(wobbling)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TonearmHost<Content>, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }
}

/// Holds the arm with its pivot at the stage origin. Rotate only the hosted
/// contents: AppKit owns the backing layer's transform and resets it during
/// layout, which otherwise leaves a paused arm resting on the record.
final class TonearmHost<Content: View>: NSView {
    private let arm: NSHostingView<Content>
    private let stage = NSView()
    private var width: CGFloat
    private var height: CGFloat
    private var pivotY: CGFloat
    private(set) var motion: TonearmMotionController!

    init(arm: Content, engaged: Bool, progress: Double, wobbling: Bool,
         width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        self.arm = NSHostingView(rootView: arm)
        self.width = width
        self.height = height
        self.pivotY = pivotY
        super.init(frame: .zero)
        stage.wantsLayer = true
        addSubview(stage)
        stage.addSubview(self.arm)
        motion = TonearmMotionController(layer: stage.layer ?? CALayer(), engaged: engaged, progress: progress)
        motion.setWobbling(wobbling)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(arm: Content, width: CGFloat, height: CGFloat, pivotY: CGFloat) {
        // The artwork depends only on geometry; clock ticks move its layer.
        // Replacing the hosting root on every tick schedules needless layout.
        guard width != self.width || height != self.height || pivotY != self.pivotY else { return }
        self.arm.rootView = arm
        self.width = width
        self.height = height
        self.pivotY = pivotY
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The arm's pivot is given from the top; AppKit layers measure it from
        // the bottom-left, where their anchor sits.
        stage.frame = CGRect(x: bounds.midX, y: bounds.height - pivotY,
                             width: width, height: height)
        arm.frame = CGRect(x: -width / 2, y: -(bounds.height - pivotY),
                           width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
