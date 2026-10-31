import Foundation

struct CachedPage<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
    let savedAt: Date

    func isFresh(maxAge: TimeInterval, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age < maxAge
    }
}

/// Display data has a bounded, account-scoped lifetime. Requests survive a
/// disappearing view; the loader must validate its login before returning.
actor PageDataCache {
    static let shared = PageDataCache(directory: KumonePaths.applicationSupport.appendingPathComponent("pages"))
    let directory: URL
    private struct Request { let id: UUID; let revision: UUID; let task: Task<Data, Error> }
    private var requests: [String: Request] = [:]
    private var revisions: [URL: UUID] = [:]
    private var activeReaders: [URL: Int] = [:]
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let now: () -> Date

    init(directory: URL, maximumEntries: Int = 512, maximumBytes: Int = 64 * 1024 * 1024,
         now: @escaping () -> Date = { .now }) {
        self.directory = directory
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.now = now
    }

    func load<Value: Codable & Sendable>(_ type: Value.Type, key: String, scope: String) -> CachedPage<Value>? {
        guard let data = try? Data(contentsOf: file(key: key, scope: scope)) else { return nil }
        return try? JSONDecoder().decode(CachedPage<Value>.self, from: data)
    }

    func fetch<Value: Codable & Sendable>(_ type: Value.Type, key: String, scope: String, maxAge: TimeInterval,
                               force: Bool = false, session: String? = nil,
                               loader: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if !force, let cached = load(type, key: key, scope: scope), cached.isFresh(maxAge: maxAge, now: now()) {
            return cached.value
        }
        let url = file(key: key, scope: scope)
        let revision = revisions[url] ?? UUID()
        revisions[url] = revision
        activeReaders[url, default: 0] += 1
        defer {
            activeReaders[url, default: 1] -= 1
            if activeReaders[url] == 0 {
                activeReaders[url] = nil
                revisions[url] = nil
            }
        }
        // A new login to the same account must not join its previous session's request.
        let requestKey = url.path + ":" + (session ?? "public")
        if let request = requests[requestKey], request.revision == revision {
            let data = try await request.task.value
            guard revisions[url] == request.revision else { throw CancellationError() }
            return try JSONDecoder().decode(CachedPage<Value>.self, from: data).value
        }
        let id = UUID()
        let fetchedAt = now
        let task = Task { @MainActor in
            let value = try await loader()
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(CachedPage(value: value, savedAt: fetchedAt()))
            // Waiters share persistence errors as well as the network result.
            // No caller may report success before the snapshot reaches disk.
            try await self.commit(data, to: url, revision: revision)
            return data
        }
        requests[requestKey] = Request(id: id, revision: revision, task: task)
        defer { if requests[requestKey]?.id == id { requests[requestKey] = nil } }
        let data = try await task.value
        // Mutations invalidate an older in-flight read, so it cannot restore
        // removed comments, rejected recommendations or an old subscription.
        guard revisions[url] == revision else { throw CancellationError() }
        return try JSONDecoder().decode(CachedPage<Value>.self, from: data).value
    }

    func save<Value: Codable & Sendable>(_ value: Value, key: String, scope: String, savedAt: Date? = nil) throws {
        let url = file(key: key, scope: scope)
        invalidateReaders(at: url)
        try write(JSONEncoder().encode(CachedPage(value: value, savedAt: savedAt ?? now())), to: url)
    }

    func remove(key: String, scope: String) throws {
        let url = file(key: key, scope: scope)
        invalidateReaders(at: url)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func file(key: String, scope: String) -> URL {
        directory.appendingPathComponent(OfflineMetadataStore.key(scope), isDirectory: true)
            .appendingPathComponent(OfflineMetadataStore.key(key) + ".json")
    }

    private func invalidateReaders(at url: URL) {
        // Only active reads need revision bookkeeping; browsing many resources
        // must not leave an unbounded in-memory map of historical cache keys.
        if activeReaders[url] != nil { revisions[url] = UUID() }
    }

    private func commit(_ data: Data, to url: URL, revision: UUID) throws {
        guard revisions[url] == revision else { throw CancellationError() }
        try write(data, to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try DownloadFileProtection.prepareDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try DownloadFileProtection.protect(url)
        try prune(keeping: url)
    }

    private func prune(keeping protected: URL) throws {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            }
        }
        var bytes = files.reduce(0) { $0 + $1.size }, count = files.count
        for file in files.sorted(by: { $0.date < $1.date }) where file.url != protected {
            guard count > maximumEntries || bytes > maximumBytes else { break }
            try FileManager.default.removeItem(at: file.url)
            invalidateReaders(at: file.url)
            count -= 1
            bytes -= file.size
        }
    }
}
