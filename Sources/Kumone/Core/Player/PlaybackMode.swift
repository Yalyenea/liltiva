import Foundation

/// The transport presents one mode even though the engine stores queue order
/// and repetition separately. Each selection writes both to avoid a hidden
/// repeat-one state surviving a switch to shuffle.
enum PlaybackMode: String, CaseIterable {
    case ordered, shuffled, repeatOne

    init(queueOrder: QueueOrder, repeatMode: RepeatMode) {
        if repeatMode == .one { self = .repeatOne }
        else if queueOrder == .shuffled { self = .shuffled }
        else { self = .ordered }
    }

    var queueOrder: QueueOrder {
        switch self {
        case .ordered, .repeatOne: return .listed
        case .shuffled: return .shuffled
        }
    }

    var repeatMode: RepeatMode {
        switch self {
        case .ordered, .shuffled: return .all
        case .repeatOne: return .one
        }
    }

    func next() -> Self {
        switch self {
        case .ordered: return .shuffled
        case .shuffled: return .repeatOne
        case .repeatOne: return .ordered
        }
    }

    var displayName: String {
        switch self {
        case .ordered: return String(localized: "列表顺序")
        case .shuffled: return String(localized: "随机播放")
        case .repeatOne: return String(localized: "单曲循环")
        }
    }
}

enum QueueOrder: String, Codable, Sendable, CaseIterable {
    case listed, shuffled

    init(migratingShuffle enabled: Bool) {
        self = enabled ? .shuffled : .listed
    }
}
