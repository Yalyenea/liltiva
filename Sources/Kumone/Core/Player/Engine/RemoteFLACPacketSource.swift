import AudioToolbox
import Foundation

/// FLAC frames include an absolute sample number (or fixed-block frame
/// number), so interpolation plus validated frame headers can locate a sample
/// without AudioFile's prefix scan or a whole-file seek table. RFC 9639 §9.1.
final class RemoteFLACPacketSource: RemoteAudioPacketSource {
    private struct Frame {
        let offset: Int64
        let sample: Int64
        let count: Int
    }
    private let reader: RemoteAudioRangeReader
    private let generation: UInt64
    let format: AudioStreamBasicDescription
    let cookie: Data
    let frameCount: Int64
    private let blockSize: Int
    private let maximumFrameBytes: Int
    private let bits: Int
    private var audioStart: Int64 = 0
    private var current: Frame?

    init(reader: RemoteAudioRangeReader, generation: UInt64) throws {
        self.reader = reader; self.generation = generation
        let header = try reader.read(at: 0, count: 42, generation: generation)
        guard header.count == 42, header.starts(with: Data("fLaC".utf8)), header[4] & 0x7f == 0,
              remoteBigEndian(header, at: 5, count: 3) == 34 else { throw RemoteAudioLoader.LoaderError.invalidFile }
        let info = Data(header[8..<42])
        blockSize = Int(remoteBigEndian(info, at: 2, count: 2))
        let packed = remoteBigEndian(info, at: 10, count: 8)
        frameCount = Int64(packed & 0x0f_ffff_ffff)
        bits = Int((packed >> 36) & 31) + 1
        let channels = Int((packed >> 41) & 7) + 1
        let sampleRate = Double(packed >> 44)
        let declaredMaximum = Int(remoteBigEndian(info, at: 7, count: 3))
        maximumFrameBytes = declaredMaximum > 0 ? declaredMaximum : blockSize * channels * ((bits + 7) / 8) + 1024
        guard blockSize > 0, frameCount > 0, sampleRate > 0, maximumFrameBytes > 0,
              maximumFrameBytes <= 4 * 1024 * 1024 else { throw RemoteAudioLoader.LoaderError.invalidFile }
        // Ask the system only for the metadata and decoder cookie; do not
        // ask it to seek/read FLAC packets, which scans their entire prefix.
        let metadata = try RemoteAudioFilePacketSource(reader: reader, generation: generation, hint: "flac")
        format = metadata.format; cookie = metadata.cookie
        guard format.mSampleRate == sampleRate, format.mChannelsPerFrame == channels else { throw RemoteAudioLoader.LoaderError.invalidFile }
        var offset: Int64 = 4
        var blocks = 0
        while true {
            let h = try reader.read(at: offset, count: 4, generation: generation)
            guard h.count == 4, h[0] & 0x7f != 127 else { throw RemoteAudioLoader.LoaderError.invalidFile }
            offset += 4 + Int64(remoteBigEndian(h, at: 1, count: 3))
            blocks += 1
            guard offset < reader.length, blocks < 4096 else { throw RemoteAudioLoader.LoaderError.invalidFile }
            if h[0] & 0x80 != 0 { break }
        }
        audioStart = offset
    }
    func seek(to frame: Int64) throws -> Int64 {
        if frame >= frameCount { current = nil; return frameCount }
        guard let first = try findFrame(atOrAfter: audioStart), first.sample == 0 else { throw RemoteAudioLoader.LoaderError.invalidFile }
        var lower = first
        var upperOffset = reader.length
        var upperSample = frameCount
        for _ in 0..<65_536 {
            if frame < lower.sample + Int64(lower.count) { current = lower; return lower.sample }
            if upperOffset - lower.offset <= Int64(maximumFrameBytes * 2 + 32) {
                guard let next = try nextFrame(after: lower) else { throw RemoteAudioLoader.LoaderError.invalidFile }
                lower = next
                continue
            }
            let fraction = Double(frame - lower.sample) / Double(max(1, upperSample - lower.sample))
            let estimate = lower.offset + Int64(Double(upperOffset - lower.offset) * fraction) - Int64(maximumFrameBytes)
            let probe = max(lower.offset + 1, min(upperOffset - 1, estimate))
            guard let candidate = try findFrame(atOrAfter: probe) else { upperOffset = probe; continue }
            if candidate.sample <= lower.sample || candidate.offset >= upperOffset {
                upperOffset = probe; continue
            }
            if candidate.sample <= frame { lower = candidate }
            else { upperOffset = candidate.offset; upperSample = candidate.sample }
        }
        throw RemoteAudioLoader.LoaderError.invalidFile
    }
    func readPackets(_ maximum: UInt32) throws -> RemoteAudioPacketBatch {
        var bytes = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for _ in 0..<min(maximum, 8) {
            guard let frame = current else { break }
            let next = try nextFrame(after: frame)
            let end = next?.offset ?? reader.length
            let count = Int(end - frame.offset)
            guard count > 0, count <= maximumFrameBytes + 16 else { throw RemoteAudioLoader.LoaderError.invalidFile }
            let packet = try reader.read(at: frame.offset, count: count, generation: generation)
            guard packet.count == count else { throw RemoteAudioLoader.LoaderError.invalidFile }
            descriptions.append(.init(mStartOffset: Int64(bytes.count), mVariableFramesInPacket: UInt32(frame.count), mDataByteSize: UInt32(count)))
            bytes.append(packet); current = next
        }
        return .init(bytes: bytes, descriptions: descriptions)
    }
    private func nextFrame(after frame: Frame) throws -> Frame? {
        if frame.sample + Int64(frame.count) >= frameCount { return nil }
        guard let next = try findFrame(atOrAfter: frame.offset + 2, expectedSample: frame.sample + Int64(frame.count)) else {
            throw RemoteAudioLoader.LoaderError.invalidFile
        }
        return next
    }
    private func findFrame(atOrAfter offset: Int64, expectedSample: Int64? = nil) throws -> Frame? {
        let data = try reader.read(at: offset, count: maximumFrameBytes + 32, generation: generation)
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { return nil }
        for i in 0..<(bytes.count - 6) where bytes[i] == 0xff && bytes[i + 1] & 0xfe == 0xf8 {
            if let result = parseHeader(bytes, at: i, fileOffset: offset + Int64(i)),
               expectedSample == nil || result.sample == expectedSample { return result }
        }
        return nil
    }
    private func parseHeader(_ b: [UInt8], at start: Int, fileOffset: Int64) -> Frame? {
        guard start + 6 < b.count, b[start + 3] & 1 == 0 else { return nil }
        let blockCode = Int(b[start + 2] >> 4)
        let rateCode = Int(b[start + 2] & 15)
        let channelCode = Int(b[start + 3] >> 4)
        let depthCode = Int((b[start + 3] >> 1) & 7)
        guard blockCode != 0, rateCode != 15, channelCode <= 10, depthCode != 3 else { return nil }
        let channels = channelCode < 8 ? channelCode + 1 : 2
        let depths = [bits, 8, 12, 0, 16, 20, 24, 32]
        guard channels == format.mChannelsPerFrame, depths[depthCode] == bits else { return nil }
        var cursor = start + 4
        let first = b[cursor]; cursor += 1
        var number: UInt64
        if first < 0x80 { number = UInt64(first) }
        else {
            let length = first.leadingZeroBitCount == 0 ? (~first).leadingZeroBitCount : 0
            guard length >= 2, length <= 7, cursor + length - 1 <= b.count else { return nil }
            number = UInt64(first & UInt8(0x7f >> length))
            for _ in 1..<length {
                guard b[cursor] & 0xc0 == 0x80 else { return nil }
                number = (number << 6) | UInt64(b[cursor] & 0x3f); cursor += 1
            }
        }
        var count: Int
        switch blockCode {
        case 1: count = 192
        case 2...5: count = 576 << (blockCode - 2)
        case 6:
            guard cursor < b.count else { return nil }; count = Int(b[cursor]) + 1; cursor += 1
        case 7:
            guard cursor + 1 < b.count else { return nil }
            count = (Int(b[cursor]) << 8 | Int(b[cursor + 1])) + 1; cursor += 2
        default: count = 256 << (blockCode - 8)
        }
        let rates = [0, 88_200, 176_400, 192_000, 8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 96_000]
        var rate = rateCode < 12 ? rates[rateCode] : 0
        if rateCode == 12 {
            guard cursor < b.count else { return nil }; rate = Int(b[cursor]) * 1000; cursor += 1
        } else if rateCode == 13 || rateCode == 14 {
            guard cursor + 1 < b.count else { return nil }
            rate = Int(b[cursor]) << 8 | Int(b[cursor + 1]); cursor += 2
            if rateCode == 14 { rate *= 10 }
        }
        guard cursor < b.count, rate == 0 || Double(rate) == format.mSampleRate else { return nil }
        var crc: UInt8 = 0
        for byte in b[start..<cursor] {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 == 0 ? crc &<< 1 : (crc &<< 1) ^ 7 }
        }
        guard crc == b[cursor], count > 0, count <= blockSize else { return nil }
        let sample = b[start + 1] & 1 == 1 ? number : number * UInt64(blockSize)
        guard sample < UInt64(frameCount), sample + UInt64(count) <= UInt64(frameCount) else { return nil }
        return Frame(offset: fileOffset, sample: Int64(sample), count: count)
    }
}

func remoteBigEndian(_ data: Data, at offset: Int, count: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in data[offset..<(offset + count)] { value = (value << 8) | UInt64(byte) }
    return value
}
