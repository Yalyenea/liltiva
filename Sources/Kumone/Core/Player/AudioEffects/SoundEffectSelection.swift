import Foundation

/// A single selection prevents two processors from silently stacking.
enum SoundEffectMode: String, Codable, CaseIterable, Identifiable {
    case off, aiMaster, smart, emotion, preset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return String(localized: "关闭音效")
        case .aiMaster: return "AI调音大师"
        case .smart: return "智能音效"
        case .emotion: return "情绪调音师" + String(localized: "（本地）")
        case .preset: return String(localized: "音效列表")
        }
    }
    var minimumMembership: MusicMembershipTier {
        switch self {
        case .aiMaster, .emotion: return .svip
        case .smart: return .vip
        case .off, .preset: return .free
        }
    }
}

enum AITuningPreference: String, CaseIterable, Identifiable, Codable {
    case bass = "en_bass", treble = "en_treble", vocal = "en_vocal", vibe = "en_vibe", live = "en_live"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bass: return String(localized: "低频增强")
        case .treble: return String(localized: "高频增强")
        case .vocal: return String(localized: "人声增强")
        case .vibe: return String(localized: "提升氛围感")
        case .live: return String(localized: "提升现场感")
        }
    }
}

/// Preserve the complete official parameter document while keeping access to
/// optional/versioned DSP groups explicit. Unknown active groups are rejected.
indirect enum SoundEffectValue: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), number(Double), bool(Bool), string(String), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var array: [Self] { if case .array(let v) = self { return v }; return [] }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    subscript(_ key: String) -> Self { object[key] ?? .null }
    func number(_ key: String, default value: Double = 0) -> Double { self[key].number ?? value }
    var enabled: Bool { self["on"].bool }
}
