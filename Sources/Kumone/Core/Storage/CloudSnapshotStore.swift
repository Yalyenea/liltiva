import Foundation

struct CloudSnapshot: Codable {
    var items: [CloudSongItem]
    var size: Int64?
    var maxSize: Int64?
    var savedAt: Date = .now

    func needsRefresh(now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age < 0 || age >= 5 * 60
    }
}

/// Cloud membership is account data, separate from evictable audio and artwork.
actor CloudSnapshotStore {
    static let shared = CloudSnapshotStore(directory: KumonePaths.applicationSupport.appendingPathComponent("cloud"))
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func load(scope: String) -> CloudSnapshot? {
        guard let data = try? Data(contentsOf: file(scope: scope)) else { return nil }
        return try? JSONDecoder().decode(CloudSnapshot.self, from: data)
    }

    func save(_ snapshot: CloudSnapshot, scope: String) throws {
        try DownloadFileProtection.prepareDirectory(directory)
        let url = file(scope: scope)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try DownloadFileProtection.protect(url)
    }

    private func file(scope: String) -> URL {
        directory.appendingPathComponent("\(OfflineMetadataStore.key(scope)).json")
    }
}
