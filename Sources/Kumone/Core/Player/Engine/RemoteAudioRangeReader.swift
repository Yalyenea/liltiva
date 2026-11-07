import Foundation

/// A bounded, seekable HTTP view. Only the decoder queue calls `read`; the
/// control lock lets seek/cancel interrupt its network wait from any thread.
final class RemoteAudioRangeReader: @unchecked Sendable {
    enum ReadError: LocalizedError {
        case invalidResponse, rangeUnsupported, resourceChanged, truncatedResponse, cancelled
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return String(localized: "音源响应异常，请重试")
            case .rangeUnsupported: return String(localized: "此音源不支持跳转，请从头播放")
            case .resourceChanged: return String(localized: "音源已更新，请重新播放")
            case .truncatedResponse: return String(localized: "音频片段未下载完整，请重试")
            case .cancelled: return String(localized: "已取消加载")
            }
        }
    }

    private struct Identity: Equatable {
        let length: Int64
        let validator: String?
        let modified: String?
        let url: URL?
    }
    private let url: URL
    private let transport = RangeSession()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var terminated = false
    private var active: RangeTransfer?
    private var transferred: Int64 = 0
    // Decoder queue only, including the LRU and resource identity.
    private var identity: Identity?
    private var blocks: [Int64: Data] = [:]
    private var recency: [Int64] = []
    private var lastFetchEnd: Int64?
    private static let blockSize: Int64 = 65_536
    private static let maximumBlocks = 32
    var lastError: Error?

    init(url: URL) { self.url = url }
    deinit { transport.invalidate() }
    var receivedByteCount: Int64 { lock.lock(); defer { lock.unlock() }; return transferred }
    var length: Int64 { identity?.length ?? 0 }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !terminated && epoch == generation
    }
    @discardableResult
    func advance(cancel: Bool = false) -> UInt64 {
        lock.lock()
        epoch &+= 1
        if cancel { terminated = true }
        let current = epoch
        let transfer = active
        active = nil
        lock.unlock()
        transfer?.cancel()
        if cancel { transport.invalidate() }
        return current
    }

    func prepare(generation: UInt64) throws {
        lastError = nil
        _ = try block(at: 0, generation: generation)
    }

    func read(at offset: Int64, count: Int, generation: UInt64) throws -> Data {
        guard offset >= 0, count >= 0, count <= 4 * 1024 * 1024 else { throw ReadError.invalidResponse }
        guard isCurrent(generation) else { throw ReadError.cancelled }
        if count == 0 || (identity != nil && offset >= length) { return Data() }
        var result = Data()
        result.reserveCapacity(Int(min(Int64(count), max(0, length - offset))))
        var cursor = offset
        while result.count < count {
            let chunk = try block(at: cursor, generation: generation)
            let base = cursor / Self.blockSize * Self.blockSize
            let start = Int(cursor - base)
            guard start < chunk.count else { break }
            let n = min(count - result.count, chunk.count - start)
            result.append(chunk[start..<(start + n)])
            cursor += Int64(n)
            if cursor >= length { break }
        }
        return result
    }

    func copy(at offset: Int64, count: Int, into destination: UnsafeMutableRawPointer,
              generation: UInt64) throws -> Int {
        guard offset >= 0, count >= 0 else { throw ReadError.invalidResponse }
        var copied = 0
        while copied < count, identity == nil || offset + Int64(copied) < length {
            let cursor = offset + Int64(copied)
            let chunk = try block(at: cursor, generation: generation)
            let start = Int(cursor % Self.blockSize)
            let n = min(count - copied, chunk.count - start)
            guard n > 0 else { break }
            chunk.withUnsafeBytes { destination.advanced(by: copied).copyMemory(from: $0.baseAddress! + start, byteCount: n) }
            copied += n
        }
        return copied
    }

    private func block(at offset: Int64, generation: UInt64) throws -> Data {
        guard isCurrent(generation) else { throw ReadError.cancelled }
        let start = offset / Self.blockSize * Self.blockSize
        if let data = blocks[start] {
            recency.removeAll { $0 == start }; recency.append(start)
            return data
        }
        guard identity == nil || start < length else { return Data() }
        // Adjacent cache misses are playback reads: amortize CDN round trips
        // with 256 KiB, while random seek probes keep their 64 KiB granularity.
        let fetchSize = lastFetchEnd == start - 1 ? Self.blockSize * 4 : Self.blockSize
        let end = identity.map { min(start + fetchSize - 1, $0.length - 1) } ?? (start + fetchSize - 1)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator = identity?.validator, !validator.hasPrefix("W/") {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        } else if let modified = identity?.modified { request.setValue(modified, forHTTPHeaderField: "If-Range") }
        let expected = identity
        let transfer = RangeTransfer(transport: transport, request: request, maximumBytes: Int(fetchSize)) { response in
            guard response.statusCode == 206 else { throw ReadError.rangeUnsupported }
            guard let value = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseContentRange(value), range.start == start,
                  range.end == min(end, range.total - 1), range.total > 0,
                  response.expectedContentLength == -1 || response.expectedContentLength == range.end - range.start + 1,
                  response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
            else { throw ReadError.invalidResponse }
            let newIdentity = Identity(length: range.total, validator: response.value(forHTTPHeaderField: "ETag"),
                                       modified: response.value(forHTTPHeaderField: "Last-Modified"), url: response.url)
            if let expected, expected != newIdentity { throw ReadError.resourceChanged }
            return range.end - range.start + 1
        }
        lock.lock()
        guard !terminated, epoch == generation else { lock.unlock(); throw ReadError.cancelled }
        active = transfer
        lock.unlock()
        defer {
            lock.lock()
            transferred += transfer.receivedBytes
            if active === transfer { active = nil }
            lock.unlock()
        }
        let result: (Data, HTTPURLResponse)
        do { result = try transfer.run() }
        catch { lastError = error; throw error }
        guard isCurrent(generation) else { throw ReadError.cancelled }
        let range = Self.parseContentRange(result.1.value(forHTTPHeaderField: "Content-Range")!)!
        identity = Identity(length: range.total, validator: result.1.value(forHTTPHeaderField: "ETag"),
                            modified: result.1.value(forHTTPHeaderField: "Last-Modified"), url: result.1.url)
        lastFetchEnd = range.end
        var relative = 0
        while relative < result.0.count {
            let key = start + Int64(relative)
            let count = min(Int(Self.blockSize), result.0.count - relative)
            blocks[key] = result.0.subdata(in: relative..<(relative + count))
            recency.removeAll { $0 == key }; recency.append(key)
            relative += count
        }
        while recency.count > Self.maximumBlocks { blocks.removeValue(forKey: recency.removeFirst()) }
        return blocks[start]!
    }

    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let limits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard limits.count == 2, let lo = Int64(limits[0]), let hi = Int64(limits[1]),
              let total = Int64(parts[1]), lo >= 0, hi >= lo, total > hi else { return nil }
        return (lo, hi, total)
    }
}

/// Delegate rejection happens at the headers, before an ignored Range can
/// turn into an accidental full-file download. Cancellation signals the wait
/// directly instead of waiting for URLSession's delegate completion.
private final class RangeTransfer: NSObject, @unchecked Sendable {
    private let transport: RangeSession
    private let condition = NSCondition()
    private let request: URLRequest
    private let maximumBytes: Int
    private let validate: (HTTPURLResponse) throws -> Int64
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var expected: Int64 = 0
    private var done = false
    private var failure: Error?
    private var byteCount: Int64 = 0
    var receivedBytes: Int64 { condition.lock(); defer { condition.unlock() }; return byteCount }
    init(transport: RangeSession, request: URLRequest, maximumBytes: Int, validate: @escaping (HTTPURLResponse) throws -> Int64) {
        self.transport = transport; self.request = request; self.maximumBytes = maximumBytes; self.validate = validate
    }
    func run() throws -> (Data, HTTPURLResponse) {
        condition.lock()
        if !done {
            self.task = transport.start(request, transfer: self)
        }
        while !done { condition.wait() }
        let error = failure
        let response = response
        let data = data
        condition.unlock()
        if let error { throw error }
        guard let response, data.count == expected else { throw RemoteAudioRangeReader.ReadError.truncatedResponse }
        return (data, response)
    }
    func cancel() {
        condition.lock()
        failure = RemoteAudioRangeReader.ReadError.cancelled; done = true
        let task = task
        condition.broadcast(); condition.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw RemoteAudioRangeReader.ReadError.invalidResponse }
            let expected = try validate(http)
            condition.lock()
            guard !done else { condition.unlock(); completionHandler(.cancel); return }
            self.response = http; self.expected = expected
            condition.unlock(); completionHandler(.allow)
        } catch {
            condition.lock(); failure = error; done = true; condition.broadcast(); condition.unlock()
            completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock(); defer { condition.unlock() }
        byteCount += Int64(data.count)
        guard !done else { return }
        guard self.data.count + data.count <= maximumBytes, self.data.count + data.count <= expected else {
            failure = RemoteAudioRangeReader.ReadError.invalidResponse; done = true; condition.broadcast(); dataTask.cancel(); return
        }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock(); defer { condition.unlock() }
        if done { return }
        failure = error
        if failure == nil, data.count != expected { failure = RemoteAudioRangeReader.ReadError.truncatedResponse }
        done = true; condition.broadcast()
    }
}

/// Keep a single connection pool for all of a song's small range requests.
/// The delegate routes by task identity, so late cancellation completions
/// cannot complete the next generation's transfer.
private final class RangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: RangeTransfer] = [:]
    private var invalidated = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func start(_ request: URLRequest, transfer: RangeTransfer) -> URLSessionDataTask? {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return nil }
        let task = session.dataTask(with: request)
        transfers[task.taskIdentifier] = transfer
        task.resume()
        return task
    }
    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        let session = session
        lock.unlock()
        session.invalidateAndCancel()
    }
    private func transfer(for task: URLSessionTask) -> RangeTransfer? {
        lock.lock(); defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask) else { completionHandler(.cancel); return }
        transfer.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = transfer(for: task)
        lock.lock(); transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        transfer?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
