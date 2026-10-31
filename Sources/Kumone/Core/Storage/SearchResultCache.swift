import Foundation

/// Search results are short-lived and kept only in memory. The login session
/// participates in the key even when a user signs back into the same account.
@MainActor
final class SearchResultCache {
    static let shared = SearchResultCache()

    struct Key: Hashable {
        let query: String
        let tab: String
        let scope: String
        let session: String?
    }

    struct Results {
        var songs: [Track] = []
        var artists: [ArtistSummary] = []
        var albums: [AlbumSummary] = []
        var playlists: [PlaylistSummary] = []
    }

    private struct Entry {
        let results: Results
        let savedAt: Date
        var access: UInt64
    }

    private let capacity: Int
    private let maxAge: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 24, maxAge: TimeInterval = 10 * 60) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
    }

    func value(for key: Key, now: Date = .now) -> Results? {
        guard var entry = entries[key] else { return nil }
        let age = now.timeIntervalSince(entry.savedAt)
        guard age >= 0, age < maxAge else {
            entries.removeValue(forKey: key)
            return nil
        }
        clock += 1
        entry.access = clock
        entries[key] = entry
        return entry.results
    }

    func insert(_ results: Results, for key: Key, now: Date = .now) {
        clock += 1
        entries[key] = Entry(results: results, savedAt: now, access: clock)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
