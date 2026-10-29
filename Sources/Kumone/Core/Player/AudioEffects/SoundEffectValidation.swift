import Foundation

/// Bounds are checked before a document reaches the real-time processor.
enum SoundEffectValidation {
    static func validate(_ groups: [String: SoundEffectValue]) throws {
        let supported: Set<String> = ["bt", "peq", "rvb", "se", "cmp", "limiter", "rotate"]
        for (key, value) in groups {
            guard !value.enabled || supported.contains(key) else { throw NCAEContainer.DecodingError.unsupportedVersion }
            try finite(value)
        }
        let peq = groups["peq"] ?? .null
        if peq.enabled {
            guard peq["f"].array.count <= 16 else { throw NCAEContainer.DecodingError.invalidPayload }
            for band in peq["f"].array where band.enabled {
                guard let frequency = band["freq"].number, (10...96_000).contains(frequency),
                      let type = band["type"].number, [0, 1, 4, 5, 6, 7, 8, 9].contains(type),
                      (0...20).contains(band.number("q")), (-24...24).contains(band.number("gain")) else {
                    throw NCAEContainer.DecodingError.invalidPayload
                }
            }
        }
        let bt = groups["bt"] ?? .null
        if bt.enabled {
            guard (-24...24).contains(bt.number("bass")), (-24...24).contains(bt.number("treble")) else {
                throw NCAEContainer.DecodingError.invalidPayload
            }
        }
    }
    private static func finite(_ value: SoundEffectValue) throws {
        switch value {
        case .number(let n):
            guard n.isFinite, abs(n) <= 1_000_000 else { throw NCAEContainer.DecodingError.invalidPayload }
        case .array(let a):
            guard a.count <= 256 else { throw NCAEContainer.DecodingError.tooLarge }
            for v in a { try finite(v) }
        case .object(let o): for v in o.values { try finite(v) }
        default: break
        }
    }
}

/// Type-2 NCAE materials contain a PCM/Float WAVE impulse, not JSON.
/// Keep the official coefficients and let the renderer resample them once.
struct SoundEffectImpulse: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channels: [[Float]]

    func validate() throws {
        guard (8_000...192_000).contains(sampleRate), (1...2).contains(channels.count),
              let frames = channels.first?.count, (1...32_768).contains(frames),
              channels.allSatisfy({ $0.count == frames && $0.allSatisfy { $0.isFinite && abs($0) <= 16 } }) else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
    }

    static func decode(wave: Data) throws -> Self {
        let b = [UInt8](wave)
        func uint(_ offset: Int, _ length: Int) -> Int {
            (0..<length).reduce(0) { $0 | Int(b[offset + $1]) << (8 * $1) }
        }
        guard b.count >= 44, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE", uint(4, 4) + 8 == b.count else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
        var format: (Int, Int, Int, Int)?
        var pcm: Range<Int>?
        var offset = 12
        while offset + 8 <= b.count {
            let count = uint(offset + 4, 4), start = offset + 8
            guard count <= b.count - start else { throw NCAEContainer.DecodingError.invalidPayload }
            let id = String(bytes: b[offset..<offset + 4], encoding: .ascii)
            if id == "fmt ", count >= 16 { format = (uint(start, 2), uint(start + 2, 2), uint(start + 4, 4), uint(start + 14, 2)) }
            if id == "data" { pcm = start..<start + count }
            offset = start + count + count % 2
        }
        guard let (type, count, rate, bits) = format, let pcm, (1...2).contains(count),
              (type == 1 && bits == 16) || (type == 3 && bits == 32), pcm.count % (bits / 8 * count) == 0 else {
            throw NCAEContainer.DecodingError.invalidPayload
        }
        let frames = pcm.count / (bits / 8 * count)
        guard (1...32_768).contains(frames) else { throw NCAEContainer.DecodingError.tooLarge }
        var channels = Array(repeating: [Float](), count: count)
        for frame in 0..<frames {
            for channel in 0..<count {
                let position = pcm.lowerBound + (frame * count + channel) * bits / 8
                let value = bits == 16 ? Float(Int16(bitPattern: UInt16(uint(position, 2)))) / 32768
                    : Float(bitPattern: UInt32(uint(position, 4)))
                channels[channel].append(value)
            }
        }
        let result = Self(sampleRate: Double(rate), channels: channels)
        try result.validate()
        return result
    }
}
