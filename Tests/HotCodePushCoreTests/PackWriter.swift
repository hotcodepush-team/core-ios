import Foundation
@testable import HotCodePushCore
import zlib

/// Writes the pack format the SDK reads, as the CLI and the edge Worker do: a patch entry's `patches/{from}` in the ustar prefix.
enum PackWriter {
    static func pack(_ entries: [PackEntry]) -> Data {
        var data = Data()
        for entry in entries {
            switch entry {
            case .file(let sha256, let body):
                append(prefix: "", name: sha256, body: body, to: &data)
            case .patch(let fromSha256, let toSha256, let body):
                append(prefix: "patches/\(fromSha256)", name: toSha256, body: body, to: &data)
            }
        }
        data.append(Data(count: 1024))
        return data
    }

    /// One entry under any name, the ustar magic only beside a prefix as the writers set it.
    static func append(prefix: String, name: String, body: Data, to data: inout Data) {
        var header = Data(count: 512)
        header.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
        if !prefix.isEmpty {
            header.replaceSubrange(257..<265, with: Data("ustar\u{0}00".utf8))
            header.replaceSubrange(345..<(345 + prefix.utf8.count), with: Data(prefix.utf8))
        }
        let size = String(format: "%011o", body.count)
        header.replaceSubrange(124..<(124 + 11), with: Data(size.utf8))
        header.replaceSubrange(148..<156, with: Data(repeating: 0x20, count: 8))
        let checksum = header.reduce(0) { $0 + Int($1) }
        header.replaceSubrange(148..<(148 + 7), with: Data((String(format: "%06o", checksum) + "\u{0}").utf8))
        data.append(header)
        data.append(body)
        data.append(Data(count: (512 - body.count % 512) % 512))
    }
}

/// Gzip as the CLI writes every file it uploads.
extension Gzip {
    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.corrupt(status) }
        defer { deflateEnd(&stream) }
        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var input = [UInt8](data)
        return try input.withUnsafeMutableBufferPointer { inputPointer -> Data in
            stream.next_in = inputPointer.baseAddress
            stream.avail_in = UInt32(inputPointer.count)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkPointer in
                    stream.next_out = chunkPointer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw Failure.corrupt(status) }
                    output.append(chunkPointer.baseAddress!, count: chunkSize - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END
            return output
        }
    }
}
