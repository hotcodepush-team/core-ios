import Foundation
import zlib

/// Decodes a pack entry, the gzip bytes the bucket serves, into the file's content on disk.
public enum Gzip {
    public enum Failure: Error, Equatable {
        case corrupt(Int32)
        case tooLarge(maximumBytes: Int)
        case unwritable
    }

    private static let chunkSize = 64 * 1024

    /// Inflates into the file chunk by chunk, so a large file never lies in memory whole, and at most `maximumBytes`, the file's
    /// size: a few bytes that would inflate to gigabytes are refused on the way. Empty input is an empty file.
    public static func decompress(_ data: Data, to file: URL, maximumBytes: Int) throws {
        guard let output = OutputStream(url: file, append: false) else { throw Failure.unwritable }
        output.open()
        defer { output.close() }
        guard !data.isEmpty else { return }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.corrupt(status) }
        defer { inflateEnd(&stream) }
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var inflatedBytes = 0
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkPointer in
                    stream.next_out = chunkPointer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw Failure.corrupt(status) }
                    let inflated = chunkSize - Int(stream.avail_out)
                    inflatedBytes += inflated
                    guard inflatedBytes <= maximumBytes else { throw Failure.tooLarge(maximumBytes: maximumBytes) }
                    try write(UnsafeBufferPointer(rebasing: chunkPointer[0..<inflated]), to: output)
                }
            } while status != Z_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
        }
        guard status == Z_STREAM_END else { throw Failure.corrupt(status) }
    }

    private static func write(_ bytes: UnsafeBufferPointer<UInt8>, to output: OutputStream) throws {
        var offset = 0
        while offset < bytes.count {
            guard let base = bytes.baseAddress else { return }
            let written = output.write(base.advanced(by: offset), maxLength: bytes.count - offset)
            guard written > 0 else { throw Failure.unwritable }
            offset += written
        }
    }
}
