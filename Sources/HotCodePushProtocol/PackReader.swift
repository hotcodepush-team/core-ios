import Foundation

/// One entry of a pack: the file's hash and its stored bytes, gzip as the bucket serves them.
public struct PackEntry {
    public let sha256: String
    public let body: Data

    public init(sha256: String, body: Data) {
        self.sha256 = sha256
        self.body = body
    }
}

/// Reads the pack format: an uncompressed ustar archive whose entries are named by their content hash and whose end is two zero blocks.
public enum PackReader {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidHeader
        case unterminated
    }

    private static let blockSize = 512
    private static let checksumRange = 148..<156

    public static func entries(in data: Data) throws -> [PackEntry] {
        var entries: [PackEntry] = []
        try forEachEntry(in: data) { entries.append($0) }
        return entries
    }

    /// Reads entry after entry up to the two end-of-archive blocks: a pack that ends before them is refused, a header whose checksum does not add up is refused, and anything after the end is ignored.
    public static func forEachEntry(in data: Data, _ body: (PackEntry) throws -> Void) throws {
        var offset = 0
        while true {
            let header = try block(at: offset, in: data)
            if isZero(header) {
                guard isZero(try block(at: offset + blockSize, in: data)) else { throw Failure.unterminated }
                return
            }
            try verifyChecksum(of: header)
            let name = string(in: header, from: 0, length: 100)
            guard let size = Int(string(in: header, from: 124, length: 12), radix: 8), size >= 0 else { throw Failure.invalidHeader }
            let start = offset + blockSize
            let end = start + size
            guard end <= data.count else { throw Failure.truncated }
            try body(PackEntry(sha256: name, body: data.subdata(in: start..<end)))
            offset = start + ((size + blockSize - 1) / blockSize) * blockSize
        }
    }

    /// The ustar checksum: the sum of the header's bytes with the checksum field read as spaces, stored in octal.
    private static func verifyChecksum(of header: Data) throws {
        guard let expected = Int(string(in: header, from: checksumRange.lowerBound, length: checksumRange.count), radix: 8) else { throw Failure.invalidHeader }
        var actual = 0
        for (index, byte) in header.enumerated() {
            actual += checksumRange.contains(index) ? 0x20 : Int(byte)
        }
        guard actual == expected else { throw Failure.invalidHeader }
    }

    private static func block(at offset: Int, in data: Data) throws -> Data {
        guard offset + blockSize <= data.count else { throw Failure.unterminated }
        return data.subdata(in: offset..<(offset + blockSize))
    }

    private static func isZero(_ block: Data) -> Bool {
        return block.allSatisfy { $0 == 0 }
    }

    private static func string(in header: Data, from start: Int, length: Int) -> String {
        let field = header.subdata(in: (header.startIndex + start)..<(header.startIndex + start + length))
        let bytes = field.prefix { $0 != 0 }
        return (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }
}
