import Foundation

/// All entry points use the same account and keys as the visible pages.
@MainActor
extension NeteaseAPI {
    static func cachedLibraryValue<Value: Codable & Sendable>(_ type: Value.Type, key: String, maxAge: TimeInterval,
                                                   force: Bool = false,
                                                   load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let scope = AccountStore.shared.offlineScope
        let session = NeteaseClient.shared.authenticationFingerprint
        let loader = {
            guard scope == AccountStore.shared.offlineScope,
                  session == NeteaseClient.shared.authenticationFingerprint else { throw CancellationError() }
            let value = try await load()
            guard scope == AccountStore.shared.offlineScope,
                  session == NeteaseClient.shared.authenticationFingerprint else { throw CancellationError() }
            return value
        }
        guard let scope else { return try await loader() }
        return try await PageDataCache.shared.fetch(type, key: key, scope: scope, maxAge: maxAge,
                                                   force: force, session: session, loader: loader)
    }

    static func cachedAlbum(id: Int, force: Bool = false) async throws -> AlbumDetailResponse {
        try await cachedLibraryValue(AlbumDetailResponse.self, key: "album:\(id)", maxAge: 86_400, force: force) {
            try await album(id: id)
        }
    }

    static func cachedArtist(id: Int, force: Bool = false) async throws -> ArtistResponse {
        try await cachedLibraryValue(ArtistResponse.self, key: "artist:\(id)", maxAge: 3600, force: force) {
            try await artist(id: id)
        }
    }

    static func cachedArtistAlbums(id: Int, limit: Int, force: Bool = false) async throws -> [AlbumSummary] {
        try await cachedLibraryValue([AlbumSummary].self, key: "artist-albums:\(id):\(limit)", maxAge: 3600, force: force) {
            try await artistAlbums(id: id, limit: limit).hotAlbums
        }
    }

    static func dailyCacheKey(now: Date = .now) -> String { "daily" }

    static func dailyCacheMaxAge(now: Date = .now) -> TimeInterval {
        // Daily recommendations roll over at 06:00 in the service's timezone,
        // independent of the listener's local clock or daylight saving time.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let today = calendar.startOfDay(for: now).addingTimeInterval(6 * 3600)
        let boundary = now < today ? today.addingTimeInterval(-86_400) : today
        return now.timeIntervalSince(boundary)
    }

    static func cachedDailyRecommendSongs(force: Bool = false) async throws -> [Track] {
        try await cachedLibraryValue([Track].self, key: dailyCacheKey(), maxAge: dailyCacheMaxAge(), force: force) {
            try await dailyRecommendSongs()
        }
    }

    static func cachedPlayRecords(uid: Int, week: Bool, force: Bool = false) async throws -> [PlayRecordItem] {
        try await cachedLibraryValue([PlayRecordItem].self, key: "records:\(uid):\(week)", maxAge: 60, force: force) {
            try await playRecords(uid: uid, week: week)
        }
    }

    static func cachedLyrics(id: Int) async throws -> LyricResponse {
        try await cachedLibraryValue(LyricResponse.self, key: "lyrics:\(id)", maxAge: 7 * 86_400) {
            try await lyric(id: id)
        }
    }
}

@MainActor
enum PlaylistPlayback {
    static func start(id: Int) async throws {
        let scope = AccountStore.shared.offlineScope
        let session = AccountStore.shared.socialSession
        let resolved = try await PlayerService.shared.resolve(.playlist(id: id, name: ""))
        guard scope == AccountStore.shared.offlineScope, session == AccountStore.shared.socialSession,
              let resolved else { throw CancellationError() }
        let saved = scope == nil ? nil : await PlaylistSnapshotStore.shared.load(id: id, scope: scope!)
        guard scope == AccountStore.shared.offlineScope, session == AccountStore.shared.socialSession else { throw CancellationError() }
        PlayerService.shared.play(tracks: resolved.tracks, source: resolved.source,
                                  context: .playlist(id: id, name: saved?.detail.name ?? ""))
    }
}
