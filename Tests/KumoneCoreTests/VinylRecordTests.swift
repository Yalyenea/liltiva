import Testing
import Foundation
import QuartzCore
import SwiftUI
@testable import KumoneCore

@Suite("Vinyl Record Tests")
struct VinylRecordTests {
    @Test(arguments: [false, true]) @MainActor
    func pausedTonearmRemainsParkedAfterNativeLayout(initiallyPlaying: Bool) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = TonearmHost(arm: Color.clear, engaged: initiallyPlaying, progress: 0.5, wobbling: false,
                               width: 101.5, height: 175, pivotY: 12.18)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        if initiallyPlaying { host.motion.setEngaged(false, progress: 0.5, animated: true) }
        let stage = try #require(host.subviews.first)
        let layer = try #require(stage.layer)
        let parked = 32.0 * .pi / 180
        #expect(abs((layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double ?? 0) - parked) < 1e-10)

        for progress in [0.0, 0.5, 1.0] {
            host.motion.setEngaged(true, progress: progress, animated: true)
            host.motion.setWobbling(true)
            host.motion.setEngaged(false, progress: progress, animated: true)
            host.motion.setWobbling(false)
            let spring = try #require(layer.animation(forKey: "tonearm-engage") as? CASpringAnimation)
            #expect(spring.keyPath == "sublayerTransform.rotation.z")
            #expect(spring.toValue as? Double == parked)
            #expect(layer.animation(forKey: "tonearm-wobble") == nil)
        }

        // Window resizing and page layout must not reset the model angle.
        host.frame.size = CGSize(width: 350, height: 350)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        host.motion.setEngaged(false, progress: 0.5, animated: false)
        #expect(abs((layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double ?? 0) - parked) < 1e-10)
    }

    @Test @MainActor func stylusTraversesThePlayableBandEvenly() throws {
        let layer = CALayer()
        let motion = TonearmMotionController(layer: layer, engaged: true, progress: 0)
        // Reconstruct the displayed needle contact point in disc-diameter units.
        // This checks radial travel, independently of the angle interpolation.
        let headAngle: Double = 39 * .pi / 180
        let contactOffset: Double = 0.56 * 0.15 * 0.35
        let tipX: Double = 0.56 * 0.58 * 0.4 + contactOffset * sin(headAngle)
        let tipY: Double = 0.56 * 0.7 + contactOffset * cos(headAngle)
        for (progress, expectedRadius) in [(0.0, 0.48), (0.25, 0.44125), (0.5, 0.4025), (0.75, 0.36375), (1.0, 0.325)] {
            motion.setEngaged(true, progress: progress, animated: false)
            let angle = -(try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double))
            let x = 0.03 + tipX * cos(angle) - tipY * sin(angle)
            let y = 0.56 * 0.58 * 0.12 + tipX * sin(angle) + tipY * cos(angle)
            #expect(abs(hypot(x, y - 0.72) - expectedRadius) < 1e-10)
        }
    }

    @Test @MainActor func tonearmTracksProgressWithoutNeedingAPlayPauseChange() throws {
        let layer = CALayer()
        let motion = TonearmMotionController(layer: layer, engaged: true, progress: 0)
        let start = try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double)
        motion.setEngaged(true, progress: 0.5, animated: false)
        let middle = try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double)
        motion.setEngaged(true, progress: 1, animated: false)
        let end = try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double)
        #expect(start > middle && middle > end)

        // Seeking backward must move the same layer back to its earlier groove.
        motion.setEngaged(true, progress: 0, animated: false)
        let rewound = try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double)
        #expect(abs(rewound - start) < 1e-12)
        motion.setEngaged(false, progress: 0, animated: false)
        let parked = layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double
        motion.setEngaged(false, progress: 1, animated: false)
        #expect(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double == parked)
        motion.setEngaged(true, progress: 1, animated: false)
        let resumed = try #require(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double)
        #expect(abs(resumed - end) < 1e-12)
    }

    @Test @MainActor func tonearmClampsProgressAndClearsAnimationForImmediateUpdates() throws {
        let layer = CALayer()
        let motion = TonearmMotionController(layer: layer, engaged: true, progress: 0)
        let start = layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double
        for progress in [-1.0, .nan, .infinity] {
            motion.setEngaged(true, progress: progress, animated: false)
            #expect(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double == start)
        }
        motion.setEngaged(true, progress: 1, animated: true)
        #expect(layer.animation(forKey: "tonearm-engage") != nil)
        let end = layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double
        motion.setEngaged(true, progress: 2, animated: false)
        #expect(layer.value(forKeyPath: "sublayerTransform.rotation.z") as? Double == end)
        motion.setEngaged(true, progress: 0, animated: false)
        #expect(layer.animation(forKey: "tonearm-engage") == nil)
    }

    @Test func rotationStateAngleCalculation() {
        var state = RecordRotationState(degreesPerSecond: 20)
        let t0 = Date(timeIntervalSince1970: 1000)

        // Before starting: angle is 0
        #expect(state.currentAngle(at: t0) == 0)
        #expect(!state.isAnimating)

        // Start at t0
        state.start(at: t0)
        #expect(state.isAnimating)

        // After 2.5 seconds: angle should be 50 degrees
        let t1 = Date(timeIntervalSince1970: 1002.5)
        #expect(state.currentAngle(at: t1) == 50.0)

        // Stop at t1
        state.stop(at: t1)
        #expect(!state.isAnimating)
        #expect(state.currentAngle(at: t1) == 50.0)

        // Even after time passes while stopped, angle stays at 50 degrees (no jumping)
        let t2 = Date(timeIntervalSince1970: 1010.0)
        #expect(state.currentAngle(at: t2) == 50.0)

        // Resume at t2: continues smoothly from 50 degrees
        state.start(at: t2)
        #expect(state.isAnimating)
        let t3 = Date(timeIntervalSince1970: 1011.0)
        #expect(state.currentAngle(at: t3) == 70.0)
    }

    @Test func nowPlayingModeCases() {
        #expect(NowPlayingMode.allCases.contains(.vinyl))
        #expect(NowPlayingMode.vinyl.displayName == "黑胶模式")
    }
}
