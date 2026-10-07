import Foundation

/// One entry of a pack: a file's stored object, gzip as the bucket serves it, named by the file's content hash, or a
/// BSDIFF40 patch that turns the file `fromSha256` into the file `toSha256`.
public enum PackEntry: Equatable {
    case file(sha256: String, body: Data)
    case patch(fromSha256: String, toSha256: String, body: Data)
}

/// Reads the pack format: an uncompressed ustar archive of file entries named by their content hash and patch entries named
/// `patches/{from}/{to}` through the ustar prefix, whose end is two zero blocks.
public enum PackReader {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidHeader
        case unterminated
    }

    private static let blockSize = 512
    private static let checksumRange = 148..<156
    private static let nameRange = 0..<100
    private static let prefixRange = 345..<500
    private static let sizeRange = 124..<136

    public static func entries(in data: Data) throws -> [PackEntry] {
        var entries: [PackEntry] = []
        try forEachEntry(in: data) { entries.append($0) }
        return entries
    }

    /// Reads entry after entry up to the two end-of-archive blocks: a pack that ends before them is refused, a header whose
    /// checksum does not add up is refused, an entry named neither by a content hash nor `patches/{hash}/{hash}` is skipped
    /// with its body, so a later kind does not break this reader, and anything after the end is ignored.
    public static func forEachEntry(in data: Data, _ body: (PackEntry) throws -> Void) throws {
        var offset = 0
        while true {
            let header = try block(at: offset, in: data)
            if isZero(header) {
                guard isZero(try block(at: offset + blockSize, in: data)) else { throw Failure.unterminated }
                return
            }
            try verifyChecksum(of: header)
            guard let size = Int(string(in: header, range: sizeRange), radix: 8), size >= 0 else { throw Failure.invalidHeader }
            let start = offset + blockSize
            let end = start + size
            guard end <= data.count else { throw Failure.truncated }
            if let entry = resolveEntry(named: resolveName(of: header), body: { data[(data.startIndex + start)..<(data.startIndex + end)] }) {
                try body(entry)
            }
            offset = start + ((size + blockSize - 1) / blockSize) * blockSize
        }
    }

    /// The entry's full name: `prefix/name` when the prefix field holds one.
    private static func resolveName(of header: Data) -> String {
        let name = string(in: header, range: nameRange)
        let prefix = string(in: header, range: prefixRange)
        return prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    /// The kind a full name gives an entry, `nil` for a name of neither kind; the body is a slice of the pack, never a copy, so a
    /// pack mapped from disk is read without holding its entries in memory.
    private static func resolveEntry(named name: String, body: () -> Data) -> PackEntry? {
        if WireRule.sha256.accepts(name) {
            return .file(sha256: name, body: body())
        }
        let segments = name.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, segments[0] == "patches", WireRule.sha256.accepts(segments[1]), WireRule.sha256.accepts(segments[2]) else { return nil }
        return .patch(fromSha256: segments[1], toSha256: segments[2], body: body())
    }

    /// The ustar checksum: the sum of the header's bytes with the checksum field read as spaces, stored in octal.
    private static func verifyChecksum(of header: Data) throws {
        guard let expected = Int(string(in: header, range: checksumRange), radix: 8) else { throw Failure.invalidHeader }
        var actual = 0
        for (index, byte) in header.enumerated() {
            actual += checksumRange.contains(index) ? 0x20 : Int(byte)
        }
        guard actual == expected else { throw Failure.invalidHeader }
    }

    private static func block(at offset: Int, in data: Data) throws -> Data {
        guard offset + blockSize <= data.count else { throw Failure.unterminated }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + blockSize))
    }

    private static func isZero(_ block: Data) -> Bool {
        return block.allSatisfy { $0 == 0 }
    }

    private static func string(in header: Data, range: Range<Int>) -> String {
        let field = header.subdata(in: (header.startIndex + range.lowerBound)..<(header.startIndex + range.upperBound))
        let bytes = field.prefix { $0 != 0 }
        return (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }
}
