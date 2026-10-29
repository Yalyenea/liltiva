import AudioToolbox
import AVFoundation
import Foundation
import KumoneObjC

/// The serial playback queue owns configuration; the AU atomically adopts a
/// prepared kernel at the next render boundary. No audio callback enters Swift.
final class LocalSoundEffectRenderer {
    private static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
        componentSubType: 0x6c667831, componentManufacturer: 0x4c696c74, componentFlags: 0, componentFlagsMask: 0)
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(LiltivaSoundEffectUnit.self, as: description,
                                     name: "Liltiva: Sound Effects", version: 1)
    }()
    let node: AVAudioUnitEffect

    init() {
        _ = Self.registration
        node = AVAudioUnitEffect(audioComponentDescription: Self.description)
    }

    func configure(effect: AISoundEffect?, strength: Double, sampleRate: Double) {
        // validate() runs when loading/composing; encoding cannot fail for a
        // validated tree of finite numbers. Keep the bypass document explicit.
        let groups = effect?.aev2.groups ?? [:]
        let json = try! JSONEncoder().encode(groups)
        let unit = node.auAudioUnit as! LiltivaSoundEffectUnit
        func bytes(_ samples: [Float]?) -> Data? {
            samples?.withUnsafeBytes { Data($0) }
        }
        unit.configureParameters(json, sampleRate: sampleRate, strength: effect == nil ? 0 : strength,
            impulseLeft: bytes(effect?.impulse?.channels.first),
            impulseRight: bytes(effect?.impulse?.channels.last),
            impulseSampleRate: effect?.impulse?.sampleRate ?? 0)
    }
}
