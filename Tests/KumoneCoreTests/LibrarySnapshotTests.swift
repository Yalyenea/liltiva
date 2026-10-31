import Foundation
import Testing
@testable import KumoneCore

@Suite("Library snapshot compatibility")
struct LibrarySnapshotTests {
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/library-snapshot-\(UUID())")
    }

    private func profile() throws -> UserProfile {
        try JSONDecoder().decode(UserProfile.self, from: Data(#"{"userId":42,"nickname":"Fixture"}"#.utf8))
    }

    @Test func olderSnapshotsWithoutCollectionsStillRestoreAccount() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountSnapshotStorage(url: directory.appendingPathComponent("account.json"))
        let original = AccountSnapshot(authenticationFingerprint: "fixture", profile: try profile(),
                                       likedTrackIDs: [1, 2], playlists: [], savedAt: Date())
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldJSON.removeValue(forKey: "likedAlbums")
        oldJSON.removeValue(forKey: "likedArtists")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: storage.url)
        let restored = try #require(storage.load(fingerprint: "fixture"))
        #expect(restored.profile.userId == 42)
        #expect(restored.likedTrackIDs == [1, 2])
        #expect(restored.likedAlbums == nil && restored.likedArtists == nil)
    }

    @Test func emptyCollectionsRemainPresentAfterRestart() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AccountSnapshotStorage(url: directory.appendingPathComponent("account.json"))
        try storage.save(AccountSnapshot(authenticationFingerprint: "fixture", profile: try profile(),
                                         likedTrackIDs: [], playlists: [], savedAt: Date(),
                                         likedAlbums: [], likedArtists: []))
        let restored = try #require(AccountSnapshotStorage(url: storage.url).load(fingerprint: "fixture"))
        // An empty successful result must not be confused with an unrequested list.
        #expect(restored.likedAlbums?.isEmpty == true)
        #expect(restored.likedArtists?.isEmpty == true)
        #expect(storage.load(fingerprint: "another-account") == nil)
    }

    @Test func emptyPageCachesRestoreWithoutChangingAccountScope() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PageDataCache(directory: directory)
        try await cache.save([AlbumSummary](), key: "liked-albums", scope: "netease:42")
        try await cache.save([ArtistSummary](), key: "liked-artists", scope: "netease:42")
        let reopened = PageDataCache(directory: directory)
        #expect(await reopened.load([AlbumSummary].self, key: "liked-albums", scope: "netease:42")?.value.isEmpty == true)
        #expect(await reopened.load([ArtistSummary].self, key: "liked-artists", scope: "netease:42")?.value.isEmpty == true)
        #expect(await reopened.load([AlbumSummary].self, key: "liked-albums", scope: "netease:7") == nil)
    }
}
