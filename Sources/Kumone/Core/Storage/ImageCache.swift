import Combine
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// Two-tier (memory + disk) image cache with in-flight request coalescing.
actor ImageCache {
    static let shared = ImageCache()
    typealias CachedImageHandler = @MainActor @Sendable (PlatformImage) -> Void

    private nonisolated(unsafe) let memory = NSCache<NSString, PlatformImage>()
    private let memoryPressure: DispatchSourceMemoryPressure
    nonisolated let directory: URL
    private let session: URLSession
    private let offlineArtwork: @Sendable (URL) async -> Data?
    private var generation: UInt64 = 0
    private var memoryRetentionEnabled = true
    private var memoryGeneration: UInt64 = 0
    private struct Request {
        let generation: UInt64
        let task: Task<PlatformImage?, Never>
    }
    private var inflight: [String: Request] = [:]

    init(directory: URL = KumonePaths.imageCache, session: URLSession = .shared,
         offlineArtwork: @escaping @Sendable (URL) async -> Data? = { await ImageCache.loadOfflineArtwork(for: $0) }) {
        self.directory = directory
        self.session = session
        self.offlineArtwork = offlineArtwork
        // Keep many small row thumbnails, but bound decoded cover storage.
        // Disk originals remain available when an evicted cover is revisited.
        memory.countLimit = 2_000
        memory.totalCostLimit = 24 * 1024 * 1024
        let cache = memory
        memoryPressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure.setEventHandler { cache.removeAllObjects() }
        memoryPressure.resume()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { memoryPressure.cancel() }

    private static func loadOfflineArtwork(for url: URL) async -> Data? {
        guard let scope = await MainActor.run(body: { AccountStore.shared.offlineScope }) else { return nil }
        return await OfflineMetadataStore.shared.artwork(url: url, scope: scope)
    }

    /// Surface local pixels before waiting for a larger version. The returned
    /// image still prefers the requested resolution, including after reconnect.
    func image(for url: URL, onCachedImage: CachedImageHandler? = nil) async -> PlatformImage? {
        let memoryKey = url.absoluteString as NSString
        if let cached = memory.object(forKey: memoryKey) {
            return cached
        }
        let key = Self.cacheKey(for: url)
        let requestGeneration = generation
        let requestMemoryGeneration = memoryGeneration
        // The exact file, decoded once: it is both the preview and the answer.
        let exact = onCachedImage == nil ? nil : diskImage(for: key, requestedURL: url)
        if let onCachedImage, let preview = exact ?? cachedVariant(for: url) {
            await onCachedImage(preview)
        }
        guard !Task.isCancelled else { return nil }
        // Delivering the preview hops to MainActor; another caller may have
        // completed the exact request while this actor was suspended.
        if let cached = memory.object(forKey: memoryKey) { return cached }
        if let existing = inflight[key] {
            let result = await existing.task.value
            return result ?? cachedVariant(for: url)
        }
        let task = Task<PlatformImage?, Never> { [self] in
            let fileURL = directory.appendingPathComponent(key)
            if let image = exact ?? diskImage(for: key, requestedURL: url) {
                return image
            }
            if let data = await offlineArtwork(url),
               let image = Self.decode(data, for: url) { return image }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = Self.decode(data, for: url) else { return nil }
            if generation == requestGeneration { try? data.write(to: fileURL, options: .atomic) }
            return image
        }
        inflight[key] = Request(generation: requestGeneration, task: task)
        let result = await task.value
        if inflight[key]?.generation == requestGeneration { inflight[key] = nil }
        if generation == requestGeneration, memoryRetentionEnabled,
           memoryGeneration == requestMemoryGeneration, let result {
            // NSImage.size is measured in points; charge the decoded pixels,
            // including row alignment, so high-density images cannot undercount.
            if let pixels = result.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                memory.setObject(result, forKey: memoryKey,
                                 cost: pixels.bytesPerRow * pixels.height)
            }
        }
        // Do not store a smaller fallback under the requested size: a later
        // online request must still be able to fetch the full-resolution image.
        return result ?? cachedVariant(for: url)
    }

    private func diskImage(for key: String, requestedURL: URL) -> PlatformImage? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)) else { return nil }
        return Self.decode(data, for: requestedURL)
    }

    private static func thumbnailLimit(for url: URL) -> Int {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "param" })?.value else { return 1_024 }
        let dimensions = value.split(separator: "y", omittingEmptySubsequences: false)
        guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
              width > 0, height > 0 else { return 1_024 }
        // Covers have no full-resolution editing use in this app. Preserve
        // Retina artwork while preventing oversized URLs from allocating originals.
        return min(max(width, height), 2_048)
    }

    /// A CDN size hint is not a decode limit: offline artwork and older cache
    /// variants can contain the original cover. Decode thumbnails on this
    /// actor before SwiftUI displays them, with a bounded pixel allocation.
    private static func decode(_ data: Data, for url: URL) -> PlatformImage? {
        let limit = thumbnailLimit(for: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        return platformImage(image)
    }

    private static func platformImage(_ image: CGImage) -> PlatformImage {
        return PlatformImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func preview(_ image: PlatformImage, for url: URL) -> PlatformImage? {
        let limit = thumbnailLimit(for: url)
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard max(pixels.width, pixels.height) > limit else { return image }
        let scale = Double(limit) / Double(max(pixels.width, pixels.height))
        let width = max(1, Int(Double(pixels.width) * scale))
        let height = max(1, Int(Double(pixels.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        return platformImage(thumbnail)
    }

    private func cachedVariant(for url: URL) -> PlatformImage? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "param" }) == true else { return nil }
        let otherItems = components.queryItems?.filter { $0.name != "param" } ?? []
        // Sizes used by app surfaces, including existing on-disk caches from
        // before cross-size fallback. Probe largest first without a disk scan.
        let sizes = [1024, 768, 640, 512, 384, 256, 160, 128, 120, 96, 80, 64, 48]
        for size in [nil] + sizes.map(Optional.some) {
            components.queryItems = otherItems + (size.map { [URLQueryItem(name: "param", value: "\($0)y\($0)")] } ?? [])
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            guard let candidate = components.url, candidate != url else { continue }
            if let image = memory.object(forKey: candidate.absoluteString as NSString),
               let preview = Self.preview(image, for: url) { return preview }
            let key = Self.cacheKey(for: candidate)
            if let image = diskImage(for: key, requestedURL: url) { return image }
        }
        return nil
    }

    func usage() throws -> CacheUsage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return CacheUsage(bytes: bytes)
    }

    /// Existing views may finish loading their image, but requests started
    /// before the clear cannot refill either disk or memory caches afterwards.
    func clear() throws {
        generation += 1
        memory.removeAllObjects()
        if FileManager.default.fileExists(atPath: directory.path) {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw OfflineAudioError.invalidResource }
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Active views own their pixels; evict unused covers before another
    /// full-window surface allocates its rendering buffers. Earlier requests
    /// must not immediately fill the memory cache again.
    func trimMemory() {
        memoryGeneration += 1
        memory.removeAllObjects()
    }

    /// Keep shared loads and disk files available while browsing is covered
    /// or the window is hidden, without retaining their decoded images.
    func setMemoryRetentionEnabled(_ enabled: Bool) {
        guard memoryRetentionEnabled != enabled else { return }
        memoryRetentionEnabled = enabled
        // Loads started before hiding or while hidden must not refill memory
        // when they finish after the window returns.
        memoryGeneration += 1
        if !enabled {
            memory.removeAllObjects()
        }
    }

    /// Synchronous in-memory lookup — safe off the actor (`NSCache` is
    /// thread-safe). Returns nil unless the image is resident in memory; use
    /// `image(for:)` for disk/network loads.
    nonisolated func cachedImage(for url: URL) -> PlatformImage? {
        // Hashing is only necessary for disk filenames, not hot row lookups.
        memory.object(forKey: url.absoluteString as NSString)
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keep pixels bound to their source, even while SwiftUI reuses a view for a
/// different URL or a cancelled request finishes after the next one starts.
struct CachedImageState {
    private(set) var url: URL?
    private var image: PlatformImage?

    init(url: URL? = nil, image: PlatformImage? = nil) {
        self.url = url
        self.image = image
    }

    func image(for url: URL?) -> PlatformImage? {
        guard let url, self.url == url else { return nil }
        return image
    }

    mutating func finish(_ image: PlatformImage?, for url: URL) {
        guard self.url == url else { return }
        self.image = image
    }
}

/// Own decoded pixels outside SwiftUI's hidden-window update cycle.
@MainActor
final class CachedImageStorage: ObservableObject {
    @Published private(set) var state: CachedImageState
    @Published private(set) var isOnScreen: Bool
    private(set) var generation: UInt64 = 0
    private var visibilitySubscription: AnyCancellable?

    init(url: URL?, visibility: MainWindowVisibility? = nil) {
        let visibility = visibility ?? .shared
        let onScreen = visibility.isOnScreen
        isOnScreen = onScreen
        let image = onScreen ? url.flatMap { ImageCache.shared.cachedImage(for: $0) } : nil
        state = CachedImageState(url: url, image: image)
        visibilitySubscription = visibility.$isOnScreen
            .removeDuplicates()
            .sink { [weak self] isOnScreen in
                guard let self, self.isOnScreen != isOnScreen else { return }
                if !isOnScreen {
                    // SwiftUI may miss the hidden interval. The generation
                    // still changes its task ID when the window returns.
                    self.generation += 1
                    self.state = CachedImageState()
                }
                self.isOnScreen = isOnScreen
            }
    }

    func reset(for url: URL? = nil, image: PlatformImage? = nil) {
        state = isOnScreen ? CachedImageState(url: url, image: image) : CachedImageState()
    }

    func finish(_ image: PlatformImage?, for url: URL) {
        guard isOnScreen else { return }
        state.finish(image, for: url)
    }
}

/// AsyncImage replacement backed by `ImageCache`, with a crossfade reveal.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var animated: Bool = true
    @ViewBuilder var placeholder: () -> Placeholder

    @StateObject private var imageStorage: CachedImageStorage

    private struct RequestID: Equatable {
        let url: URL?
        let isOnScreen: Bool
        let generation: UInt64
    }

    init(url: URL?, animated: Bool = true,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.animated = animated
        self.placeholder = placeholder
        // Seed inside the object so StateObject's initial closure captures no
        // image that could outlive the storage's explicit release on hide.
        _imageStorage = StateObject(wrappedValue: CachedImageStorage(url: url))
    }

    var body: some View {
        ZStack {
            placeholder()
            // A reused row keeps its State. Resolve an already decoded cover
            // synchronously when the URL changes, before the new task runs.
            if imageStorage.isOnScreen,
               let image = imageStorage.state.image(for: url) ?? url.flatMap({ ImageCache.shared.cachedImage(for: $0) }) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(animated ? .opacity.animation(.easeIn(duration: 0.22)) : .identity)
            }
        }
        .task(id: RequestID(url: url, isOnScreen: imageStorage.isOnScreen, generation: imageStorage.generation)) {
            guard imageStorage.isOnScreen, let url else {
                imageStorage.reset()
                return
            }
            let generation = imageStorage.generation
            // Synchronous memory hit first — no actor hop, no placeholder frame.
            let memoryHit = ImageCache.shared.cachedImage(for: url)
            if imageStorage.state.url != url || memoryHit != nil {
                imageStorage.reset(for: url, image: memoryHit)
            }
            guard memoryHit == nil else { return }
            let cached = await ImageCache.shared.image(for: url) { preview in
                guard !Task.isCancelled, imageStorage.isOnScreen,
                      imageStorage.generation == generation else { return }
                imageStorage.finish(preview, for: url)
            }
            guard !Task.isCancelled, imageStorage.isOnScreen,
                  imageStorage.generation == generation, let cached else { return }
            imageStorage.finish(cached, for: url)
        }
    }
}

extension CachedAsyncImage where Placeholder == AnyView {
    /// Default placeholder: a quiet neutral fill with a music note.
    init(url: URL?, animated: Bool = true) {
        self.init(url: url, animated: animated) {
            AnyView(
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
            )
        }
    }
}
