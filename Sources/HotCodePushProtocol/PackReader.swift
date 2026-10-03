import Foundation

/// One entry of a pack: the file's hash and its stored bytes, gzip as the bucket serves them.
public struct PackEntry {
    public let sha256: String
    public let body: Data
}

/// Reads the pack format: an uncompressed ustar archive whose entries are named by their content hash and whose end is two zero blocks.
public enum PackReader {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidHeader
        case unterminated
    }

    private static let blockSize = 512

    public static func entries(in data: Data) throws -> [PackEntry] {
        var entries: [PackEntry] = []
        try forEachEntry(in: data) { entries.append($0) }
        return entries
    }

    /// Reads entry after entry up to the two end-of-archive blocks: a pack that ends before them is refused, and anything after them is ignored.
    public static func forEachEntry(in data: Data, _ body: (PackEntry) throws -> Void) throws {
        var offset = 0
        while true {
            let header = try block(at: offset, in: data)
            if isZero(header) {
                guard isZero(try block(at: offset + blockSize, in: data)) else { throw Failure.unterminated }
                return
            }
            let name = string(in: header, from: 0, length: 100)
            guard let size = Int(string(in: header, from: 124, length: 12), radix: 8), size >= 0 else { throw Failure.invalidHeader }
            let start = offset + blockSize
            let end = start + size
            guard end <= data.count else { throw Failure.truncated }
            try body(PackEntry(sha256: name, body: data.subdata(in: start..<end)))
            offset = start + ((size + blockSize - 1) / blockSize) * blockSize
        }
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
