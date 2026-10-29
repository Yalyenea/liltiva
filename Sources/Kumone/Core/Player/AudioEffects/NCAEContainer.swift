import Foundation
import zlib

/// NCAE v1: a 17-byte header, an obfuscated per-file key, then an encrypted
/// raw DEFLATE payload. No installed client, shared secret or executable code
/// is needed to read the parameter document returned for the current account.
enum NCAEContainer {
    enum DecodingError: Error { case invalidHeader, unsupportedVersion, invalidPayload, tooLarge }
    static let maximumPackageBytes = 1_048_576
    static let maximumJSONBytes = 2_097_152

    enum MaterialKind: Int { case parameters = 1, impulse = 2 }
    struct Material { let kind: MaterialKind; let data: Data }

    static func decode(_ data: Data) throws -> Data {
        let material = try decodeMaterial(data)
        guard material.kind == .parameters else { throw DecodingError.unsupportedVersion }
        return material.data
    }

    static func decodeMaterial(_ data: Data) throws -> Material {
        guard data.count <= maximumPackageBytes else { throw DecodingError.tooLarge }
        let bytes = [UInt8](data)
        guard bytes.count >= 22, Array(bytes.prefix(4)) == Array("NCAE".utf8) else {
            throw DecodingError.invalidHeader
        }
        let version = Int(bytes[12]) | Int(bytes[13]) << 8
        let type = Int(bytes[14]) | Int(bytes[15]) << 8
        guard version == 1, let kind = MaterialKind(rawValue: type) else { throw DecodingError.unsupportedVersion }
        let length = (0..<4).reduce(0) { $0 | Int(bytes[4 + $1]) << (8 * $1) }
        let keyCount = Int(bytes[16])
        let payloadStart = 17 + keyCount
        guard keyCount >= 5, (keyCount - 1).isMultiple(of: 4),
              length > 0, payloadStart <= bytes.count, bytes.count - payloadStart == length else {
            throw DecodingError.invalidHeader
        }
        let keyBlock = Array(bytes[17..<payloadStart])
        let mask = keyBlock[4]
        let key = keyBlock.enumerated().compactMap { $0.offset == 4 ? nil : $0.element ^ mask }

        // Key scheduling matches the container's 256-byte substitution table.
        // Its stream uses a fixed table and byte offset, rather than RC4's
        // stateful swap step, so decoding is independent of chunk boundaries.
        var table = Array(UInt8.min...UInt8.max)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(table[i]) + Int(key[i % key.count])) & 255
            table.swapAt(i, j)
        }
        var compressed = Data(count: length)
        compressed.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for offset in 0..<length {
                let i = (offset + 1) & 255
                let a = Int(table[i])
                let stream = table[(a + Int(table[(i + a) & 255])) & 255]
                output[offset] = bytes[payloadStart + offset] ^ stream
            }
        }
        return Material(kind: kind, data: try inflate(compressed))
    }

    private static func inflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DecodingError.invalidPayload
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                var produced = 0
                let status = chunk.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = destination.count - Int(stream.avail_out)
                    return status
                }
                guard output.count + produced <= maximumJSONBytes else { throw DecodingError.tooLarge }
                output.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw DecodingError.invalidPayload }
                    return output
                }
                guard status == Z_OK, produced > 0 else { throw DecodingError.invalidPayload }
            }
        }
    }
}
