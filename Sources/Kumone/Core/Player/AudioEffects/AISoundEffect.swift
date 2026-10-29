import AVFoundation
import Foundation

/// Official parameters are composed before rendering. NetEase's proprietary
/// spatial/reverb engine is implemented locally, so its output is not bit exact.
struct AISoundEffect: Codable, Equatable, Sendable {
    struct Parameters: Codable, Equatable, Sendable {
        struct Equalizer: Codable, Equatable, Sendable {
            var on: Bool
            var eqs: [Double]
        }
        var eq: Equalizer
        var groups: [String: SoundEffectValue]

        init(eq: Equalizer = .init(on: false, eqs: Array(repeating: 0, count: 10)),
             groups: [String: SoundEffectValue] = [:]) {
            self.eq = eq
            self.groups = groups
        }

        init(from decoder: Decoder) throws {
            groups = try [String: SoundEffectValue](from: decoder)
            let value = groups.removeValue(forKey: "eq") ?? .null
            eq = Equalizer(on: value.enabled, eqs: value["eqs"].array.compactMap(\.number))
            if !eq.on && eq.eqs.isEmpty { eq.eqs = Array(repeating: 0, count: 10) }
        }

        func encode(to encoder: Encoder) throws {
            var values = groups
            values["eq"] = .object(["on": .bool(eq.on), "eqs": .array(eq.eqs.map(SoundEffectValue.number))])
            try values.encode(to: encoder)
        }
        subscript(_ group: String) -> SoundEffectValue {
            get { groups[group] ?? .null }
            set { groups[group] = newValue }
        }
    }
    var aev2: Parameters
    let effectStyle: String?
    var feature: SoundEffectValue? = nil
    var impulse: SoundEffectImpulse? = nil

    enum CodingKeys: String, CodingKey { case aev2, feature, impulse; case effectStyle = "effect_style" }

    func validate() throws {
        guard aev2.eq.eqs.count == 10,
              aev2.eq.eqs.allSatisfy({ $0.isFinite && (-24...24).contains($0) }) else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
        try SoundEffectValidation.validate(aev2.groups)
        try impulse?.validate()
    }

    static func decode(package: Data) throws -> Self {
        let payload = try NCAEContainer.decodeMaterial(package)
        let effect: Self
        if payload.kind == .impulse {
            effect = Self(aev2: .init(), effectStyle: nil, impulse: try SoundEffectImpulse.decode(wave: payload.data))
        } else {
            let value = try JSONDecoder().decode(SoundEffectValue.self, from: payload.data)
            let parameters = value["aev2"] == .null ? value : value["aev2"]
            effect = Self(aev2: try JSONDecoder().decode(Parameters.self, from: JSONEncoder().encode(parameters)),
                          effectStyle: value["effect_style"].stringValue, feature: value.object["feature"])
        }
        try effect.validate()
        return effect
    }

    static let frequencies: [Double] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    func gains(strength: Double) -> [Double] {
        let scale = strength.isFinite ? min(1, max(0, strength)) : 0
        return aev2.eq.eqs.map { aev2.eq.on ? $0 * scale : 0 }
    }

    static func configure(_ equalizer: AVAudioUnitEQ, effect: Self?, strength: Double, sampleRate: Double) {
        guard let effect, effect.aev2.eq.on, strength.isFinite, strength > 0 else {
            equalizer.globalGain = 0
            equalizer.bypass = true
            return
        }
        let gains = effect.gains(strength: strength)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Float(min(frequencies[index], sampleRate * 0.45))
            band.bandwidth = 1
            band.gain = Float(gains[index])
            band.bypass = false
        }
        equalizer.globalGain = Float(preampDB(gains: gains, sampleRate: sampleRate))
        equalizer.bypass = gains.allSatisfy { $0 == 0 }
    }

    /// Leave headroom for the combined response, including adjacent bands.
    /// This is a fixed EQ preamp; it never measures or normalizes song loudness.
    static func preampDB(gains: [Double], sampleRate: Double) -> Double {
        guard gains.count == frequencies.count, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        var maximum = 0.0
        for index in 0..<1024 {
            let frequency = 20 * pow(min(24_000, sampleRate * 0.49) / 20, Double(index) / 1023)
            let response = zip(frequencies, gains).reduce(0.0) { sum, band in
                sum + responseDB(frequency: frequency, center: min(band.0, sampleRate * 0.45), gain: band.1, sampleRate: sampleRate)
            }
            maximum = max(maximum, response)
        }
        return maximum > 0.01 ? -(maximum + 1) : 0
    }

    private static func responseDB(frequency: Double, center: Double, gain: Double, sampleRate: Double) -> Double {
        guard gain != 0 else { return 0 }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * center / sampleRate
        let alpha = sin(w) * sinh(log(2) / 2 * w / sin(w)) // one octave
        let b = [1 + alpha * a, -2 * cos(w), 1 - alpha * a]
        let d = [1 + alpha / a, -2 * cos(w), 1 - alpha / a]
        let omega = 2 * Double.pi * frequency / sampleRate
        func power(_ coefficients: [Double]) -> Double {
            let real = coefficients[0] + coefficients[1] * cos(omega) + coefficients[2] * cos(2 * omega)
            let imaginary = -coefficients[1] * sin(omega) - coefficients[2] * sin(2 * omega)
            return real * real + imaginary * imaginary
        }
        return 10 * log10(power(b) / power(d))
    }
}

enum SoundEffectState: Equatable {
    case off, requiresLogin, requiresSVIP, unauthorized, waiting, loading, ready, unavailable, offlineMissing, unsupportedSource, failed

    var displayName: String {
        switch self {
        case .off: return String(localized: "音效已关闭")
        case .requiresLogin: return String(localized: "登录后可使用音效")
        case .requiresSVIP: return String(localized: "需要黑胶 SVIP")
        case .unauthorized: return String(localized: "当前账号暂无此音效权益")
        case .waiting: return String(localized: "播放后自动加载音效")
        case .loading: return String(localized: "正在加载音效…")
        case .ready: return String(localized: "音效已应用")
        case .unavailable: return String(localized: "暂无可用音效")
        case .offlineMissing: return String(localized: "联网后可加载此音效")
        case .unsupportedSource: return String(localized: "空间音质暂不支持音效")
        case .failed: return String(localized: "音效加载失败，请重试")
        }
    }
}
