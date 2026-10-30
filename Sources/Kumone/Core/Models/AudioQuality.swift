import Foundation

enum MusicMembershipTier: Int, Codable, Comparable {
    case free, vip, svip

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .free: return String(localized: "普通账号")
        case .vip: return String(localized: "黑胶 VIP")
        case .svip: return String(localized: "黑胶 SVIP")
        }
    }
}

/// Loyalty level (redVipLevel) is independent of SVIP. Only a live
/// associator/redplus entitlement grants its corresponding quality tier.
struct MusicMembership: Codable, Equatable {
    struct Benefit: Codable, Equatable {
        let vipCode: Int
        let expireTime: Double

        func isActive(at date: Date) -> Bool {
            expireTime / 1000 > date.timeIntervalSince1970
        }
    }

    let associator: Benefit?
    let redplus: Benefit?

    func tier(at date: Date = .now) -> MusicMembershipTier {
        if redplus?.isActive(at: date) == true { return .svip }
        if associator?.isActive(at: date) == true { return .vip }
        return .free
    }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard, higher, exhigh, lossless, hires, jyeffect, jymaster
    case sky, dolby, vivid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        case .jyeffect: return String(localized: "高清臻音")
        case .jymaster: return String(localized: "超清母带")
        case .sky: return String(localized: "沉浸环绕声")
        case .dolby: return String(localized: "杜比全景声")
        case .vivid: return String(localized: "臻音全景声")
        }
    }

    var requiredMembership: MusicMembershipTier {
        switch self {
        case .standard, .higher, .exhigh: return .free
        case .lossless, .hires, .jyeffect: return .vip
        case .jymaster, .sky, .dolby, .vivid: return .svip
        }
    }

    static func available(for tier: MusicMembershipTier) -> [Self] {
        allCases.filter { $0.requiredMembership <= tier }
    }

    var isSpatial: Bool { [.sky, .dolby, .vivid].contains(self) }

    /// AVPlayer preserves the source's high sample rate and spatial metadata;
    /// the PCM streaming graph uses stereo / 44.1 kHz.
    var usesNativePlayback: Bool { [.hires, .jyeffect, .jymaster, .sky, .dolby, .vivid].contains(self) }

    /// Enhanced and spatial editions are distinct mixes. A menu's order must
    /// never make one replace the recording the listener actually selected.
    func canSubstitute(for requested: Self) -> Bool {
        if self == requested { return true }
        let original: [Self] = [.standard, .higher, .exhigh, .lossless, .hires]
        guard let stored = original.firstIndex(of: self), let desired = original.firstIndex(of: requested) else { return false }
        return stored >= desired
    }

    static func canSubstitute(_ stored: String, for requested: String) -> Bool {
        guard let stored = Self(rawValue: stored), let requested = Self(rawValue: requested) else { return false }
        return stored.canSubstitute(for: requested)
    }
}
