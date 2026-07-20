import Compression
import Foundation

enum GzipDecoder {
    static func decodeIfNeeded(_ data: Data) throws -> Data {
        guard data.count >= 2, data[0] == 0x1f, data[1] == 0x8b else { return data }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> Data {
        guard data.count >= 18, data[2] == 8 else {
            throw ScanError.invalidFile("The gzip header is truncated or uses an unknown compression method.")
        }

        let flags = data[3]
        guard flags & 0xe0 == 0 else {
            throw ScanError.invalidFile("The gzip header contains reserved flags.")
        }

        var cursor = 10
        if flags & 0x04 != 0 {
            guard cursor + 2 <= data.count else { throw ScanError.invalidFile("The gzip extra field is truncated.") }
            let length = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2 + length
        }
        if flags & 0x08 != 0 { cursor = try skipZeroTerminatedField(in: data, from: cursor) }
        if flags & 0x10 != 0 { cursor = try skipZeroTerminatedField(in: data, from: cursor) }
        if flags & 0x02 != 0 { cursor += 2 }

        guard cursor < data.count - 8 else { throw ScanError.invalidFile("The gzip payload is missing.") }
        let trailer = data.count - 8
        let expectedSize = UInt32(data[trailer + 4])
            | (UInt32(data[trailer + 5]) << 8)
            | (UInt32(data[trailer + 6]) << 16)
            | (UInt32(data[trailer + 7]) << 24)
        guard expectedSize > 0, expectedSize <= 1_073_741_824 else {
            throw ScanError.unsupported("Its expanded size is invalid or exceeds the 1 GB safety limit.")
        }
        try ScanResourceBudget.validateGzip(
            compressedBytes: data.count,
            expandedBytes: Int(expectedSize)
        )

        let payload = data[cursor..<trailer]
        var output = [UInt8](repeating: 0, count: Int(expectedSize))
        let capacity = output.count
        let decodedCount = payload.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == capacity else {
            throw ScanError.invalidFile("The gzip payload is corrupt or truncated.")
        }

        let expectedCRC = UInt32(data[trailer])
            | (UInt32(data[trailer + 1]) << 8)
            | (UInt32(data[trailer + 2]) << 16)
            | (UInt32(data[trailer + 3]) << 24)
        guard CRC32.checksum(output) == expectedCRC else {
            throw ScanError.invalidFile("The gzip checksum does not match its contents.")
        }
        return Data(output)
    }

    private static func skipZeroTerminatedField(in data: Data, from start: Int) throws -> Int {
        guard start < data.count else { throw ScanError.invalidFile("The gzip header is truncated.") }
        guard let end = data[start...].firstIndex(of: 0) else {
            throw ScanError.invalidFile("The gzip header contains an unterminated text field.")
        }
        return end + 1
    }
}

private enum CRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        let table = (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value >> 1) ^ (0xedb88320 & (0 &- (value & 1)))
            }
            return value
        }
        var crc = UInt32.max
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ UInt32.max
    }
}
