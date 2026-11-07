import AVFoundation
import AudioToolbox
import Foundation

struct RemoteAudioPacketBatch {
    var bytes: Data
    var descriptions: [AudioStreamPacketDescription]
}

protocol RemoteAudioPacketSource: AnyObject {
    var format: AudioStreamBasicDescription { get }
    var cookie: Data { get }
    var frameCount: Int64 { get }
    /// Returns the source sample at the start of the first packet. Audible
    /// sample zero excludes an encoder's priming frames.
    func seek(to frame: Int64) throws -> Int64
    func readPackets(_ maximum: UInt32) throws -> RemoteAudioPacketBatch
}

/// Pulls only the HTTP ranges needed for the requested playback position.
/// The source rate remains intact for high-resolution effects. File parsing,
/// network waits, and C AudioConverter decoding run on a private queue.
final class RemoteAudioLoader: @unchecked Sendable {
    var onFormat: ((AVAudioFormat) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onCompleted: (() -> Void)?
    var onError: ((Error) -> Void)?

    enum LoaderError: LocalizedError {
        case unsupportedFormat, parseFailed(OSStatus), decodeFailed(OSStatus), invalidFile, missingSeekIndex
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return String(localized: "此音频格式暂不支持跳转播放")
            case .parseFailed: return String(localized: "无法定位播放位置，请重试")
            case .decodeFailed: return String(localized: "无法解码这段音频，请重试")
            case .invalidFile: return String(localized: "无法读取音频信息，请重试")
            case .missingSeekIndex: return String(localized: "这首 MP3 缺少跳转索引，请从头播放")
            }
        }
    }

    private let reader: RemoteAudioRangeReader
    private let hint: String?
    private let requestedOutput: AVAudioFormat
    private let preserveSampleRate: Bool
    private let callbackQueue: DispatchQueue
    private let workQueue = DispatchQueue(label: "app.kumone.remote-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var initialPosition: TimeInterval
    private var started = false
    private var suspended = false
    private var duration: TimeInterval?
    private var finished = false
    private var ready = false
    // Decoder queue only. A new generation disposes both before seeking.
    private var generation: UInt64 = 0
    private var source: RemoteAudioPacketSource?
    private var converter: AudioConverterRef?
    private var output: AVAudioFormat?
    private var feed: RemoteConverterFeed?
    private var discardFrames: Int64 = 0
    private var remainingFrames: Int64 = 0

    init(remoteURL: URL, formatHint: String?, output: AVAudioFormat, queue: DispatchQueue,
         preserveSampleRate: Bool = false, initialPosition: TimeInterval = 0) {
        reader = RemoteAudioRangeReader(url: NeteaseCDNHost.preferred(for: remoteURL))
        hint = formatHint?.lowercased(); requestedOutput = output
        callbackQueue = queue; self.preserveSampleRate = preserveSampleRate
        self.initialPosition = max(0, initialPosition.isFinite ? initialPosition : 0)
    }
    deinit { reader.advance(cancel: true); if let converter { AudioConverterDispose(converter) } }
    var estimatedDuration: TimeInterval? { lock.lock(); defer { lock.unlock() }; return duration }
    var canSeek: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    var downloadFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var receivedByteCount: Int64 { reader.receivedByteCount }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let position = initialPosition
        lock.unlock()
        let generation = reader.advance()
        workQueue.async { self.prepare(at: position, generation: generation) }
    }
    func cancel() {
        reader.advance(cancel: true)
        workQueue.async { self.disposeDecoder() }
    }
    func seek(to seconds: TimeInterval) {
        let position = max(0, seconds.isFinite ? seconds : 0)
        lock.lock(); finished = false; suspended = false; lock.unlock()
        // Advancing synchronously suppresses already queued callbacks before
        // returning to the engine, and immediately wakes any network wait.
        let generation = reader.advance()
        workQueue.async { self.prepare(at: position, generation: generation) }
    }
    func setDownloadSuspended(_ suspend: Bool) {
        lock.lock(); suspended = suspend; lock.unlock()
        if !suspend { workQueue.async { self.pump(generation: self.generation) } }
    }
    private var isSuspended: Bool { lock.lock(); defer { lock.unlock() }; return suspended }
    private func disposeDecoder() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil; feed = nil; source = nil; output = nil
    }
    private func prepare(at seconds: TimeInterval, generation: UInt64) {
        guard reader.isCurrent(generation) else { return }
        disposeDecoder(); self.generation = generation
        do {
            try reader.prepare(generation: generation)
            let signature = try reader.read(at: 0, count: 12, generation: generation)
            let source: RemoteAudioPacketSource
            if signature.starts(with: Data("fLaC".utf8)) {
                source = try RemoteFLACPacketSource(reader: reader, generation: generation)
            } else if signature.count >= 8 && signature[4..<8] == Data("ftyp".utf8) {
                source = try RemoteAudioFilePacketSource(reader: reader, generation: generation, hint: "m4a")
            } else if hint == "mp3" || signature.starts(with: [0x49, 0x44, 0x33]) ||
                        (hint != "aac" && signature.count > 1 && signature[0] == 0xff && signature[1] & 0xe0 == 0xe0) {
                source = try RemoteMP3PacketSource(reader: reader, generation: generation)
            } else {
                source = try RemoteAudioFilePacketSource(reader: reader, generation: generation, hint: hint)
            }
            guard source.format.mSampleRate > 0, source.frameCount > 0,
                  let output = preserveSampleRate
                    ? AVAudioFormat(standardFormatWithSampleRate: source.format.mSampleRate, channels: 2)
                    : Optional(requestedOutput) else { throw LoaderError.unsupportedFormat }
            self.source = source; self.output = output
            let boundedSeconds = min(seconds, Double(source.frameCount) / source.format.mSampleRate)
            let target = min(source.frameCount, Int64((boundedSeconds * source.format.mSampleRate).rounded(.down)))
            let first = try source.seek(to: target)
            let ratio = output.sampleRate / source.format.mSampleRate
            discardFrames = max(0, Int64((Double(target - first) * ratio).rounded()))
            remainingFrames = max(0, Int64((Double(source.frameCount - target) * ratio).rounded()))
            var input = source.format
            var out = output.streamDescription.pointee
            var converter: AudioConverterRef?
            let status = AudioConverterNew(&input, &out, &converter)
            guard status == noErr, let converter else { throw LoaderError.decodeFailed(status) }
            self.converter = converter
            if !source.cookie.isEmpty {
                let status = source.cookie.withUnsafeBytes {
                    AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                              UInt32($0.count), $0.baseAddress!)
                }
                guard status == noErr else { throw LoaderError.decodeFailed(status) }
            }
            let feed = RemoteConverterFeed(source: source)
            self.feed = feed
            lock.lock(); duration = Double(source.frameCount) / source.format.mSampleRate
            ready = true; finished = false; lock.unlock()
            deliver(generation: generation) { self.onFormat?(output) }
            pump(generation: generation)
        } catch { fail(error, generation: generation) }
    }
    private func pump(generation: UInt64) {
        guard reader.isCurrent(generation), self.generation == generation, !isSuspended,
              let converter, let output, let feed else { return }
        if remainingFrames == 0 { complete(generation: generation); return }
        let capacity = AVAudioFrameCount(max(1, output.sampleRate / 2))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            fail(LoaderError.unsupportedFormat, generation: generation); return
        }
        let list = buffer.mutableAudioBufferList
        for i in 0..<UnsafeMutableAudioBufferListPointer(list).count {
            UnsafeMutableAudioBufferListPointer(list)[i].mDataByteSize = capacity * 4
        }
        var frames = UInt32(capacity)
        let status = AudioConverterFillComplexBuffer(converter, remoteConverterInput,
            Unmanaged.passUnretained(feed).toOpaque(), &frames, list, nil)
        guard reader.isCurrent(generation) else { return }
        if let error = feed.error { fail(error, generation: generation); return }
        guard status == noErr else { fail(LoaderError.decodeFailed(status), generation: generation); return }
        if frames == 0 {
            if remainingFrames > 0 {
                fail(LoaderError.invalidFile, generation: generation)
            } else { complete(generation: generation) }
            return
        }
        let skip = min(discardFrames, Int64(frames))
        discardFrames -= skip
        let count = min(Int64(frames) - skip, remainingFrames)
        if count > 0 {
            if skip > 0 {
                for ch in 0..<Int(output.channelCount) {
                    memmove(buffer.floatChannelData![ch], buffer.floatChannelData![ch] + Int(skip), Int(count) * 4)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            remainingFrames -= count
            // One synchronous buffer delivery lets the engine apply its high
            // water mark before the decoder produces the next PCM block.
            deliver(generation: generation) { self.onBuffer?(buffer) }
        }
        guard reader.isCurrent(generation), !isSuspended else { return }
        workQueue.async { self.pump(generation: generation) }
    }
    private func deliver(generation: UInt64, _ body: () -> Void) {
        callbackQueue.sync { if self.reader.isCurrent(generation) { body() } }
    }
    private func complete(generation: UInt64) {
        guard reader.isCurrent(generation), converter != nil else { return }
        disposeDecoder()
        lock.lock(); finished = true; lock.unlock()
        deliver(generation: generation) { self.onCompleted?() }
    }
    private func fail(_ error: Error, generation: UInt64) {
        guard reader.isCurrent(generation) else { return }
        disposeDecoder()
        deliver(generation: generation) { self.onError?(error) }
    }
}

private final class RemoteConverterFeed {
    let source: RemoteAudioPacketSource
    var storage: RemotePacketStorage?
    var error: Error?
    init(source: RemoteAudioPacketSource) { self.source = source }
}
private final class RemotePacketStorage {
    let bytes: UnsafeMutableRawPointer
    let descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>
    let count: Int
    let byteCount: Int
    init(_ batch: RemoteAudioPacketBatch) {
        count = batch.descriptions.count; byteCount = batch.bytes.count
        bytes = .allocate(byteCount: max(1, byteCount), alignment: 16)
        descriptions = .allocate(capacity: max(1, count))
        batch.bytes.withUnsafeBytes { if let base = $0.baseAddress { bytes.copyMemory(from: base, byteCount: $0.count) } }
        descriptions.initialize(from: batch.descriptions, count: count)
    }
    deinit { bytes.deallocate(); descriptions.deinitialize(count: count); descriptions.deallocate() }
}
private let remoteConverterInput: AudioConverterComplexInputDataProc = { _, requested, buffers, descriptions, context in
    let feed = Unmanaged<RemoteConverterFeed>.fromOpaque(context!).takeUnretainedValue()
    do {
        let batch = try feed.source.readPackets(min(requested.pointee, 32))
        let storage = RemotePacketStorage(batch)
        feed.storage = storage
        requested.pointee = UInt32(storage.count)
        buffers.pointee.mNumberBuffers = 1
        buffers.pointee.mBuffers = AudioBuffer(mNumberChannels: feed.source.format.mChannelsPerFrame,
            mDataByteSize: UInt32(storage.byteCount), mData: storage.bytes)
        descriptions?.pointee = storage.descriptions
        return noErr
    } catch {
        feed.error = error; requested.pointee = 0
        return kAudioFileUnspecifiedError
    }
}

/// Indexed containers (notably M4A with a tail moov atom) use AudioFile's
/// native packet table. Raw FLAC/MP3 use dedicated sources because AudioFile
/// otherwise scans every preceding compressed packet during a seek.
final class RemoteAudioFilePacketSource: RemoteAudioPacketSource {
    private let reader: RemoteAudioRangeReader
    private let generation: UInt64
    private var file: AudioFileID?
    private(set) var format = AudioStreamBasicDescription()
    private(set) var cookie = Data()
    private(set) var frameCount: Int64 = 0
    private var priming: Int64 = 0
    private var packet: Int64 = 0
    private var maximumPacket: UInt32 = 0
    init(reader: RemoteAudioRangeReader, generation: UInt64, hint: String?) throws {
        self.reader = reader; self.generation = generation
        let type: AudioFileTypeID
        switch hint {
        case "m4a", "mp4", "alac": type = kAudioFileM4AType
        case "flac": type = kAudioFileFLACType
        case "wav": type = kAudioFileWAVEType
        case "aac": type = kAudioFileAAC_ADTSType
        default: type = 0
        }
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(self).toOpaque(), remoteFileRead,
                                                nil, remoteFileSize, nil, type, &file)
        guard status == noErr, let file else { throw reader.lastError ?? RemoteAudioLoader.LoaderError.parseFailed(status) }
        try get(kAudioFilePropertyDataFormat, &format)
        try get(kAudioFilePropertyPacketSizeUpperBound, &maximumPacket)
        guard maximumPacket > 0, maximumPacket <= 4 * 1024 * 1024 else { throw RemoteAudioLoader.LoaderError.invalidFile }
        var table = AudioFilePacketTableInfo()
        if (try? get(kAudioFilePropertyPacketTableInfo, &table)) != nil, table.mNumberValidFrames > 0 {
            frameCount = table.mNumberValidFrames; priming = Int64(table.mPrimingFrames)
        } else {
            var packets: UInt64 = 0
            try get(kAudioFilePropertyAudioDataPacketCount, &packets)
            guard format.mFramesPerPacket > 0,
                  packets <= UInt64(Int64.max) / UInt64(format.mFramesPerPacket) else {
                throw RemoteAudioLoader.LoaderError.invalidFile
            }
            frameCount = Int64(packets) * Int64(format.mFramesPerPacket)
        }
        var size: UInt32 = 0
        if AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &size, nil) == noErr, size > 0 {
            guard size <= 1024 * 1024 else { throw RemoteAudioLoader.LoaderError.invalidFile }
            cookie = Data(count: Int(size))
            let status = cookie.withUnsafeMutableBytes { AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &size, $0.baseAddress!) }
            guard status == noErr else { throw RemoteAudioLoader.LoaderError.parseFailed(status) }
        }
    }
    deinit { if let file { AudioFileClose(file) } }
    private func get<T>(_ property: AudioFilePropertyID, _ value: inout T) throws {
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioFileGetProperty(file!, property, &size, &value)
        guard status == noErr else { throw reader.lastError ?? RemoteAudioLoader.LoaderError.parseFailed(status) }
    }
    func seek(to frame: Int64) throws -> Int64 {
        var translation = AudioFramePacketTranslation(mFrame: frame + priming, mPacket: 0, mFrameOffsetInPacket: 0)
        try get(kAudioFilePropertyFrameToPacket, &translation)
        // AAC needs a preceding packet for its overlap; ten packets also
        // covers formats with a larger native roll distance.
        var roll = AudioPacketRollDistanceTranslation(mPacket: translation.mPacket, mRollDistance: 0)
        _ = try? get(kAudioFilePropertyPacketToRollDistance, &roll)
        packet = max(0, translation.mPacket - max(10, Int64(roll.mRollDistance)))
        var start = AudioFramePacketTranslation(mFrame: 0, mPacket: packet, mFrameOffsetInPacket: 0)
        try get(kAudioFilePropertyPacketToFrame, &start)
        return start.mFrame - priming
    }
    func readPackets(_ maximum: UInt32) throws -> RemoteAudioPacketBatch {
        var bytes = Data(count: min(4 * 1024 * 1024, Int(maximumPacket) * Int(maximum)))
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(maximum))
        var count = min(maximum, UInt32(bytes.count) / maximumPacket)
        var size = UInt32(bytes.count)
        let status = bytes.withUnsafeMutableBytes {
            AudioFileReadPacketData(file!, false, &size, &descriptions, packet, &count, $0.baseAddress)
        }
        guard status == noErr || status == kAudioFileEndOfFileError else { throw reader.lastError ?? RemoteAudioLoader.LoaderError.parseFailed(status) }
        packet += Int64(count)
        bytes.count = Int(size); descriptions.removeLast(descriptions.count - Int(count))
        if format.mBytesPerPacket > 0 {
            for i in descriptions.indices { descriptions[i] = .init(mStartOffset: Int64(i) * Int64(format.mBytesPerPacket),
                mVariableFramesInPacket: format.mFramesPerPacket, mDataByteSize: format.mBytesPerPacket) }
        }
        return .init(bytes: bytes, descriptions: descriptions)
    }
    fileprivate func read(at position: Int64, requested: UInt32, destination: UnsafeMutableRawPointer, actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        do { actual.pointee = UInt32(try reader.copy(at: position, count: Int(requested), into: destination, generation: generation)); return noErr }
        catch { reader.lastError = error; actual.pointee = 0; return kAudioFileUnspecifiedError }
    }
    fileprivate var size: Int64 { reader.length }
}
private let remoteFileRead: AudioFile_ReadProc = { context, position, requested, destination, actual in
    Unmanaged<RemoteAudioFilePacketSource>.fromOpaque(context).takeUnretainedValue()
        .read(at: position, requested: requested, destination: destination, actual: actual)
}
private let remoteFileSize: AudioFile_GetSizeProc = {
    Unmanaged<RemoteAudioFilePacketSource>.fromOpaque($0).takeUnretainedValue().size
}
