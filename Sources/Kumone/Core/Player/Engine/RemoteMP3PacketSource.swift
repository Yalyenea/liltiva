import AudioToolbox
import Foundation

/// MPEG Layer III frames are independently locatable from their headers.
/// Xing's 100 quantized offsets provide an approximate VBR timeline; they
/// cannot encode a sample-exact map. CBR uses the encoded frame length.
/// Ten preceding frames warm the MP3 bit reservoir before output is exposed.
final class RemoteMP3PacketSource: RemoteAudioPacketSource {
    private struct Header {
        let size: Int
        let rate: Int
        let channels: Int
        let samples: Int
        let bitrate: Int
        let version: Int
        let crc: Bool
    }
    private let reader: RemoteAudioRangeReader
    private let generation: UInt64
    let format: AudioStreamBasicDescription
    let cookie = Data()
    let frameCount: Int64
    private let first: Header
    private var audioStart: Int64
    private let audioEnd: Int64
    private var cursor: Int64
    private let encodedFrames: Int64
    private let delay: Int64
    private let toc: [UInt8]?
    private let isVBR: Bool
    private let bytesInStream: Int64

    init(reader: RemoteAudioRangeReader, generation: UInt64) throws {
        self.reader = reader; self.generation = generation
        let head = try reader.read(at: 0, count: 10, generation: generation)
        var offset: Int64 = 0
        if head.count == 10, head.starts(with: Data("ID3".utf8)) {
            guard head[6...9].allSatisfy({ $0 & 0x80 == 0 }) else { throw RemoteAudioLoader.LoaderError.invalidFile }
            offset = 10 + head[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
            if head[5] & 0x10 != 0 { offset += 10 }
        }
        let prefix = try reader.read(at: offset, count: 8192, generation: generation)
        var found: (Int, Header)?
        if prefix.count >= 4 {
            for i in 0..<(prefix.count - 3) {
                if let h = Self.header(prefix, at: i), i + h.size + 4 <= prefix.count,
                   let next = Self.header(prefix, at: i + h.size), next.rate == h.rate, next.samples == h.samples {
                    found = (i, h); break
                }
            }
        }
        guard let (index, first) = found else { throw RemoteAudioLoader.LoaderError.invalidFile }
        self.first = first
        offset += Int64(index)
        let packet = try reader.read(at: offset, count: first.size, generation: generation)
        let side = first.version == 3 ? (first.channels == 1 ? 17 : 32) : (first.channels == 1 ? 9 : 17)
        let tagOffset = 4 + (first.crc ? 2 : 0) + side
        var frames: Int64 = 0
        var bytes: Int64 = 0
        var table: [UInt8]?
        var delay: Int64 = 0
        var padding: Int64 = 0
        var vbr = false
        var hasXing = false
        if tagOffset + 8 <= packet.count {
            let name = String(data: packet[tagOffset..<(tagOffset + 4)], encoding: .ascii)
            if name == "Xing" || name == "Info" {
                hasXing = true; vbr = name == "Xing"
                let flags = remoteBigEndian(packet, at: tagOffset + 4, count: 4)
                var p = tagOffset + 8
                if flags & 1 != 0, p + 4 <= packet.count { frames = Int64(remoteBigEndian(packet, at: p, count: 4)); p += 4 }
                if flags & 2 != 0, p + 4 <= packet.count { bytes = Int64(remoteBigEndian(packet, at: p, count: 4)); p += 4 }
                if flags & 4 != 0, p + 100 <= packet.count { table = Array(packet[p..<(p + 100)]); p += 100 }
                if flags & 8 != 0 { p += 4 }
                if p + 24 <= packet.count {
                    // LAME-compatible encoders store 12-bit encoder delay and
                    // padding here. AudioConverter already handles its own
                    // synthesis delay, so only encoder priming is trimmed.
                    let name = String(data: packet[p..<(p + 4)], encoding: .ascii)
                    if name == "LAME" || name == "Lavc" || name == "Lavf" {
                        delay = Int64(packet[p + 21]) << 4 | Int64(packet[p + 22] >> 4)
                        padding = Int64(packet[p + 22] & 15) << 8 | Int64(packet[p + 23])
                    }
                }
            }
        }
        var end = reader.length
        if end >= 128 {
            let tail = try reader.read(at: end - 128, count: 3, generation: generation)
            if tail == Data("TAG".utf8) { end -= 128 }
        }
        // Xing describes the byte stream including its own metadata frame.
        bytesInStream = bytes > 0 ? bytes : end - offset
        if hasXing { offset += Int64(first.size) }
        audioStart = offset; audioEnd = end; cursor = offset
        if frames == 0 {
            frames = Int64((Double(end - offset) / (Double(first.bitrate) * 125 * Double(first.samples) / Double(first.rate))).rounded(.down))
        }
        guard frames > 0, end > offset else { throw RemoteAudioLoader.LoaderError.invalidFile }
        encodedFrames = frames
        self.delay = delay
        frameCount = max(1, frames * Int64(first.samples) - delay - padding)
        toc = table; isVBR = vbr
        format = AudioStreamBasicDescription(mSampleRate: Double(first.rate), mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(first.samples), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(first.channels), mBitsPerChannel: 0, mReserved: 0)
        // Detect an unindexed VBR file before promising CBR positioning.
        var probe = offset
        for _ in 0..<16 {
            let bytes = try reader.read(at: probe, count: 4, generation: generation)
            guard let h = Self.header(bytes, at: 0) else { break }
            if h.bitrate != first.bitrate && !vbr { throw RemoteAudioLoader.LoaderError.missingSeekIndex }
            probe += Int64(h.size)
        }
        if vbr, table == nil { throw RemoteAudioLoader.LoaderError.missingSeekIndex }
    }
    func seek(to frame: Int64) throws -> Int64 {
        if frame >= frameCount { cursor = audioEnd; return frameCount }
        let target = max(0, frame + delay)
        let wantedPacket = max(0, target / Int64(first.samples) - 12)
        var offset: Int64
        if let toc, isVBR {
            let percent = min(99.999, Double(wantedPacket) / Double(encodedFrames) * 100)
            let index = Int(percent)
            let a = Double(toc[index])
            let b = index == 99 ? 256 : Double(toc[index + 1])
            let fraction = (a + (b - a) * (percent - Double(index))) / 256
            offset = max(audioStart, audioStart - Int64(first.size) + Int64(fraction * Double(bytesInStream)))
        } else {
            let averageSize = Double(first.bitrate) * 125 * Double(first.samples) / Double(first.rate)
            offset = audioStart + Int64((Double(wantedPacket) * averageSize).rounded(.down))
        }
        let data = try reader.read(at: offset, count: 8192, generation: generation)
        guard data.count >= 4 else { throw RemoteAudioLoader.LoaderError.invalidFile }
        for i in 0..<(data.count - 3) {
            guard let h = Self.header(data, at: i), h.rate == first.rate, h.samples == first.samples,
                  i + h.size + 4 <= data.count, let next = Self.header(data, at: i + h.size), next.rate == h.rate else { continue }
            if !isVBR, h.bitrate != first.bitrate { throw RemoteAudioLoader.LoaderError.missingSeekIndex }
            cursor = offset + Int64(i)
            if isVBR {
                // Xing offsets are quantized; expose the requested packet
                // timeline and retain the bounded approximation explicitly.
                return wantedPacket * Int64(first.samples) - delay
            }
            let averageSize = Double(first.bitrate) * 125 * Double(first.samples) / Double(first.rate)
            let actualPacket = Int64((Double(cursor - audioStart) / averageSize).rounded())
            return actualPacket * Int64(first.samples) - delay
        }
        throw RemoteAudioLoader.LoaderError.invalidFile
    }
    func readPackets(_ maximum: UInt32) throws -> RemoteAudioPacketBatch {
        var bytes = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for _ in 0..<maximum {
            if cursor + 4 > audioEnd { break }
            let head = try reader.read(at: cursor, count: 4, generation: generation)
            guard let h = Self.header(head, at: 0), h.rate == first.rate, h.samples == first.samples,
                  h.channels == first.channels, cursor + Int64(h.size) <= audioEnd else { throw RemoteAudioLoader.LoaderError.invalidFile }
            if !isVBR, h.bitrate != first.bitrate { throw RemoteAudioLoader.LoaderError.missingSeekIndex }
            let packet = try reader.read(at: cursor, count: h.size, generation: generation)
            guard packet.count == h.size else { throw RemoteAudioLoader.LoaderError.invalidFile }
            descriptions.append(.init(mStartOffset: Int64(bytes.count), mVariableFramesInPacket: UInt32(h.samples), mDataByteSize: UInt32(packet.count)))
            bytes.append(packet); cursor += Int64(h.size)
        }
        return .init(bytes: bytes, descriptions: descriptions)
    }
    private static func header(_ data: Data, at i: Int) -> Header? {
        guard i + 4 <= data.count else { return nil }
        let h = UInt32(remoteBigEndian(data, at: i, count: 4))
        guard h & 0xffe0_0000 == 0xffe0_0000, (h >> 17) & 3 == 1 else { return nil }
        let version = Int((h >> 19) & 3)
        let rateIndex = Int((h >> 10) & 3)
        let bitrateIndex = Int((h >> 12) & 15)
        guard version != 1, rateIndex < 3, bitrateIndex > 0, bitrateIndex < 15 else { return nil }
        let rates = [44_100, 48_000, 32_000]
        let bitrates = version == 3 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let rate = rates[rateIndex] / (version == 3 ? 1 : (version == 2 ? 2 : 4))
        let bitrate = bitrates[bitrateIndex]
        let size = (version == 3 ? 144_000 : 72_000) * bitrate / rate + Int((h >> 9) & 1)
        return Header(size: size, rate: rate, channels: ((h >> 6) & 3) == 3 ? 1 : 2,
            samples: version == 3 ? 1152 : 576, bitrate: bitrate, version: version, crc: (h >> 16) & 1 == 0)
    }
}
