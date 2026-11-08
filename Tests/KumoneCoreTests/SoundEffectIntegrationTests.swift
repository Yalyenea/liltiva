import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

private func fixtureData(_ name: String, extension ext: String = "ncae") throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
}

@Suite("Complete sound effect rendering", .serialized)
struct SoundEffectIntegrationTests {
    @Test(arguments: AITuningPreference.allCases)
    func eachAIPreferenceChangesRenderedSamples(_ preference: AITuningPreference) throws {
        let song = try AISoundEffect.decode(package: fixtureData("ai-eq"))
        let materials = try JSONDecoder().decode([String: SoundEffectValue].self, from: fixtureData("ai-diy", extension: "json"))
        let result = try AITuningComposer.compose(song: song, preferences: [preference], materials: materials)
        #expect(result.closed.isEmpty)
        let baseline = try render(song)
        let changed = try render(result.effect)
        #expect(distance(baseline, changed) > 0.0001, "\(preference) produced no audible processing")
        #expect(changed.allSatisfy { $0.isFinite && abs($0) <= 1 })
        let bypass = try render(result.effect, strength: 0)
        #expect(distance(bypass, try render(nil)) < 0.000001)
    }

    @Test func officialClosingRulesAndGainComposition() throws {
        var song = try AISoundEffect.decode(package: fixtureData("ai-eq"))
        let materials = try JSONDecoder().decode([String: SoundEffectValue].self, from: fixtureData("ai-diy", extension: "json"))
        let combined = try AITuningComposer.compose(song: song, preferences: Set(AITuningPreference.allCases), materials: materials)
        #expect(combined.closed == [.vibe: "本曲采用现场增强"])
        #expect(combined.effect.aev2["bt"].number("bass") == 4.8)
        #expect(combined.effect.aev2["bt"].number("treble") == 3.8)
        #expect(combined.effect.aev2["cmp"].number("pregain") == -3)
        song.feature = .object(["vocal_drum_bass_other_ratio": .array([.number(0.1), .number(0.01)]),
                                "vocal_main_freq": .number(700)])
        let closed = try AITuningComposer.compose(song: song, preferences: [.bass, .treble, .vocal], materials: materials)
        #expect(Set(closed.closed.keys) == [.bass, .treble, .vocal])
        #expect(closed.effect == song)
        song.aev2["rvb"] = .object(["on": .bool(true)])
        let spatial = try AITuningComposer.compose(song: song, preferences: [.vibe, .live], materials: materials)
        #expect(spatial.closed[.live] != nil)
        #expect(!spatial.effect.aev2["rvb"].enabled)
        #expect(spatial.effect.aev2["se"].enabled)
        #expect(spatial.effect.aev2["cmp"].number("pregain") == -2.5)
    }

    @Test func officialImpulseAndLegacyReverbMaterialsDecodeAndRender() throws {
        let impulse = try AISoundEffect.decode(package: fixtureData("effect-impulse"))
        #expect(impulse.impulse?.channels.count == 2)
        #expect(impulse.impulse?.sampleRate == 44_100)
        #expect(throws: NCAEContainer.DecodingError.unsupportedVersion) { _ = try NCAEContainer.decode(fixtureData("effect-impulse")) }
        let room = try AISoundEffect.decode(package: fixtureData("effect-live"))
        #expect(room.aev2["rvb"].enabled)
        #expect(!room.aev2.eq.on)
        for effect in [room, impulse] {
            let output = try render(effect, rate: 96_000)
            #expect(distance(output, try render(nil, rate: 96_000)) > 0.0001)
            #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    @Test func partitionedConvolutionMatchesADirectImpulseAtArbitraryRenderBoundaries() throws {
        let ir: [Float] = [0.5, 0.25, -0.125] + Array(repeating: 0, count: 400) + [0.1]
        let effect = AISoundEffect(aev2: .init(), effectStyle: nil,
                                  impulse: .init(sampleRate: 44_100, channels: [ir]))
        for block: AVAudioFrameCount in [17, 257, 4096] {
            let samples = try render(effect, block: block, impulseInput: true)
            for i in 0..<samples.count / 2 {
                let expected: Float = (i >= 256 && i - 256 < ir.count) ? ir[i - 256] * 0.5 : 0
                #expect(abs(samples[i * 2] - expected) < 0.00001, "FIR mismatch at \(i), block \(block)")
            }
        }
    }

    @Test func stereoAndRotationActuallyChangeLeftRightImage() throws {
        for group: [String: SoundEffectValue] in [
            ["se": .object(["on": .bool(true), "stereoizer": .number(4), "sshaper": .bool(true)])],
            ["rotate": .object(["on": .bool(true), "velocity": .number(90)])]
        ] {
            let samples = try render(AISoundEffect(aev2: .init(groups: group), effectStyle: nil))
            let difference = stride(from: 0, to: samples.count, by: 2).reduce(0.0) { $0 + abs(Double(samples[$1] - samples[$1 + 1])) }
            #expect(difference / Double(samples.count / 2) > 0.0001)
        }
    }

    @Test func unsupportedActiveGroupsAndInvalidImpulseAreRejected() {
        let unsupported = AISoundEffect(aev2: .init(groups: ["futureDSP": .object(["on": .bool(true)])]), effectStyle: nil)
        #expect(throws: NCAEContainer.DecodingError.unsupportedVersion) { try unsupported.validate() }
        #expect(throws: (any Error).self) { try SoundEffectImpulse(sampleRate: 44_100, channels: [[.nan]]).validate() }
        #expect(throws: (any Error).self) { _ = try SoundEffectImpulse.decode(wave: Data(repeating: 0, count: 44)) }
    }

    @Test func seekResetClearsReverbAndConvolutionHistory() throws {
        let impulse = AISoundEffect(aev2: .init(), effectStyle: nil, impulse: .init(sampleRate: 44_100,
            channels: [[0.5] + Array(repeating: 0, count: 8190) + [0.25]]))
        let reverb = try AISoundEffect.decode(package: fixtureData("effect-live"))
        for effect in [impulse, reverb] {
            let ringing = try render(effect, block: 512, impulseInput: true)
            let cleared = try render(effect, block: 512, impulseInput: true, resetAtFrame: 2048)
            #expect(ringing.dropFirst(4096 * 2).contains { abs($0) > 0.000001 })
            #expect(cleared.dropFirst(4096 * 2).allSatisfy { abs($0) < 0.000001 })
        }
    }

    private func distance(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0) { $0 + abs(Double($1.0 - $1.1)) } / Double(a.count)
    }

    private func render(_ effect: AISoundEffect?, strength: Double = 1, rate: Double = 44_100,
                        block: AVAudioFrameCount = 4096, impulseInput: Bool = false,
                        resetAtFrame: AVAudioFrameCount? = nil) throws -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), renderer = LocalSoundEffectRenderer()
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        AISoundEffect.configure(eq, effect: effect, strength: strength, sampleRate: rate)
        renderer.configure(effect: effect, strength: strength, sampleRate: rate)
        for node in [player, eq, renderer.node] { engine.attach(node) }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: renderer.node, format: format)
        engine.connect(renderer.node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        let frames = AVAudioFrameCount(rate * 0.4)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        input.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                input.floatChannelData![channel][i] = impulseInput ? (i == 0 ? 0.5 : 0)
                    : [80.0, 1000, 7000].reduce(Float(0)) { $0 + 0.06 * Float(sin(2 * .pi * $1 * Double(i) / rate)) }
            }
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input)
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        var result: [Float] = [], rendered: AVAudioFrameCount = 0
        var didReset = false
        while rendered < frames {
            if let resetAtFrame, rendered >= resetAtFrame, !didReset {
                renderer.node.reset()
                eq.reset()
                didReset = true
            }
            let status = try engine.renderOffline(min(block, frames - rendered), to: output)
            #expect(status == .success)
            guard status == .success else { break }
            for i in 0..<Int(output.frameLength) { result.append(output.floatChannelData![0][i]); result.append(output.floatChannelData![1][i]) }
            rendered += output.frameLength
        }
        return result
    }
}

@Suite("Local emotion tuning")
struct EmotionSoundEffectTests {
    @Test func calmAndLivelyAnalysisProduceDifferentBoundedEffects() throws {
        func analysis(_ label: String) -> EmotionSoundAnalysis {
            .init(song_id: 1, emotion_label: label, repbpm: 100, dynamic_range: 20,
                  stereo_width_ratio: 0.3, vocal_energy_ratio: 0.6, drum_energy_ratio: 0.1, bass_energy_ratio: 0.1)
        }
        let calm = try analysis("平静,治愈,抒情").localEffect()
        let lively = try analysis("活力,快乐,自信").localEffect()
        #expect(calm.aev2.eq.eqs[8] < lively.aev2.eq.eqs[8])
        #expect(calm.aev2["se"].number("ambience") > lively.aev2["se"].number("ambience"))
        #expect(calm.aev2["cmp"].enabled)
        try calm.validate()
        try lively.validate()
        #expect(SoundEffectMode.emotion.minimumMembership == .svip)
    }
    @Test func malformedAnalysisIsRejected() {
        let invalid = EmotionSoundAnalysis(song_id: 1, emotion_label: "治愈", repbpm: 80, dynamic_range: .nan,
            stereo_width_ratio: 0.3, vocal_energy_ratio: 0.6, drum_energy_ratio: 0.1, bass_energy_ratio: 0.1)
        #expect(throws: (any Error).self) { _ = try invalid.localEffect() }
    }
}
