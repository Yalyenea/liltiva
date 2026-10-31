import AppKit
import Foundation
import Testing
@testable import KumoneCore

private final class DeferredImageProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: DeferredImageProtocol?
        func set(_ value: DeferredImageProtocol?) { lock.lock(); pending = value; lock.unlock() }
        func get() -> DeferredImageProtocol? { lock.lock(); defer { lock.unlock() }; return pending }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.set(self) }
    override func stopLoading() {}
    func finish(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        Self.state.set(nil)
    }
}

@Suite("Image cache clearing", .serialized)
struct ImageCacheClearTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XkAAAAASUVORK5CYII=")!

    private func pendingRequest() async throws -> DeferredImageProtocol {
        for _ in 0..<200 where DeferredImageProtocol.state.get() == nil { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(DeferredImageProtocol.state.get())
    }

    @Test func lateRequestDoesNotRepopulateClearedDiskOrMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-image-clear-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredImageProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        let url = URL(string: "https://example.test/image.png")!
        let first = Task { await cache.image(for: url) }
        let pending = try await pendingRequest()
        try await cache.clear()
        pending.finish(png)
        #expect(await first.value != nil)
        #expect(cache.cachedImage(for: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let second = Task { await cache.image(for: url) }
        try await pendingRequest().finish(png)
        #expect(await second.value != nil)
        #expect(cache.cachedImage(for: url) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func offlineArtworkSurvivesClearingOrdinaryImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-protected-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = OfflineMetadataStore(directory: root.appendingPathComponent("offline"))
        let url = URL(string: "https://example.test/cover.png")!
        try await metadata.saveArtwork(png, url: url, scope: "a")
        let cache = ImageCache(directory: root.appendingPathComponent("images"), offlineArtwork: { url in
            await metadata.artwork(url: url, scope: "a")
        })
        #expect(await cache.image(for: url) != nil)
        try await cache.clear()
        #expect(cache.cachedImage(for: url) == nil)
        #expect(await metadata.artwork(url: url, scope: "a") == png)
        #expect(await cache.image(for: url) != nil)
    }

    @Test func trimmingPreservesDiskAndRejectsLateMemoryRefills() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/image-trim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredImageProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        let url = URL(string: "https://example.test/transition-cover.png")!
        let first = Task { await cache.image(for: url) }
        let pending = try await pendingRequest()
        await cache.trimMemory()
        pending.finish(png)
        #expect(await first.value != nil)
        #expect(cache.cachedImage(for: url) == nil)

        #expect(await cache.image(for: url) != nil)
        let activeImage = try #require(cache.cachedImage(for: url))
        await cache.trimMemory()
        #expect(cache.cachedImage(for: url) == nil)
        #expect(activeImage.size.width > 0) // A visible surface can finish its slide.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) != nil)
    }

    @Test func disablingRetentionPurgesOnlyMemoryAndCanRestoreCaching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-image-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredImageProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        let url = URL(string: "https://example.test/image.png")!
        let first = Task { await cache.image(for: url) }
        try await pendingRequest().finish(png)
        #expect(await first.value != nil)
        #expect(cache.cachedImage(for: url) != nil)
        let diskFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let diskFile = try #require(diskFiles.first)
        #expect(diskFiles.count == 1)

        await cache.setMemoryRetentionEnabled(false)
        #expect(cache.cachedImage(for: url) == nil)
        #expect(try Data(contentsOf: diskFile) == png)
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) == nil)

        await cache.setMemoryRetentionEnabled(true)
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) != nil)
        #expect(try Data(contentsOf: diskFile) == png)
    }

    @Test(arguments: [false, true])
    func disablingRetentionLeavesSharedRequestRunningWithoutLateMemoryRefill(startedWhileHidden: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-image-inflight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredImageProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        let url = URL(string: "https://example.test/image.png")!
        if startedWhileHidden { await cache.setMemoryRetentionEnabled(false) }
        let first = Task { await cache.image(for: url) }
        let pending = try await pendingRequest()

        await cache.setMemoryRetentionEnabled(false)
        // Requests started before or during hiding must finish for their caller,
        // without restoring decoded memory when the window has already returned.
        await cache.setMemoryRetentionEnabled(true)
        pending.finish(png)
        #expect(await first.value != nil)
        #expect(cache.cachedImage(for: url) == nil)
        let diskFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(diskFiles.count == 1)
        #expect(try Data(contentsOf: #require(diskFiles.first)) == png)

        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false]) @MainActor
    func coveredPagesKeepImagesUncachedAcrossWindowChanges(restoreBrowsingWhileHidden: Bool) async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".tmp/image-visibility-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = png
        let cache = ImageCache(directory: root, offlineArtwork: { _ in png })
        let (policies, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        var updates = policies.makeAsyncIterator()
        let visibility = MainWindowVisibility(managesProcessMemory: true) { enabled in
            await cache.setMemoryRetentionEnabled(enabled)
            continuation.yield(enabled)
        }
        let url = URL(string: "https://example.test/browsing-cover.png")!
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) != nil)

        visibility.setBrowsingVisible(false)
        #expect(await updates.next() == false)
        #expect(cache.cachedImage(for: url) == nil)
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) == nil)

        visibility.update(isVisible: false, isOnScreen: false)
        #expect(await updates.next() == false)
        if restoreBrowsingWhileHidden {
            visibility.setBrowsingVisible(true)
            #expect(await updates.next() == false)
            #expect(await cache.image(for: url) != nil)
            #expect(cache.cachedImage(for: url) == nil)
            visibility.update(isVisible: true, isOnScreen: true)
        } else {
            visibility.update(isVisible: true, isOnScreen: true)
            #expect(await updates.next() == false)
            #expect(await cache.image(for: url) != nil)
            #expect(cache.cachedImage(for: url) == nil)
            visibility.setBrowsingVisible(true)
        }
        #expect(await updates.next() == true)
        #expect(await cache.image(for: url) != nil)
        #expect(cache.cachedImage(for: url) != nil)
        #expect(visibility.isOnScreen && visibility.isBrowsingVisible)
    }

    @Test @MainActor func hidingReleasesViewPixelsWithoutASwiftUIUpdate() {
        let visibility = MainWindowVisibility()
        let url = URL(string: "https://example.test/view-cover.png")!
        let storage = CachedImageStorage(url: url, visibility: visibility)
        var image: PlatformImage? = PlatformImage(size: NSSize(width: 2, height: 2))
        weak var retainedImage = image
        storage.reset(for: url, image: image)
        image = nil
        #expect(retainedImage != nil)

        visibility.update(isVisible: false, isOnScreen: false)
        #expect(storage.state.image(for: url) == nil)
        #expect(retainedImage == nil)
        #expect(!storage.isOnScreen)
    }

    @Test @MainActor func returningRequiresFreshPixelsEvenWhenSwiftUIMissesTheHiddenInterval() {
        let visibility = MainWindowVisibility()
        let url = URL(string: "https://example.test/view-cover.png")!
        let storage = CachedImageStorage(url: url, visibility: visibility)
        let image = PlatformImage(size: NSSize(width: 2, height: 2))
        storage.reset(for: url, image: image)
        let previousGeneration = storage.generation

        visibility.update(isVisible: false, isOnScreen: false)
        storage.finish(image, for: url)
        storage.reset(for: url, image: image)
        #expect(storage.state.image(for: url) == nil)

        visibility.update(isVisible: true, isOnScreen: true)
        #expect(storage.isOnScreen)
        #expect(storage.generation != previousGeneration)
        #expect(storage.state.image(for: url) == nil)
        storage.finish(image, for: url)
        #expect(storage.state.image(for: url) == nil)

        storage.reset(for: url)
        storage.finish(image, for: url)
        #expect(storage.state.image(for: url) === image)
    }
}
