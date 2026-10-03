import XCTest
@testable import HotCodePushProtocol

final class PackTests: XCTestCase {
    func testShouldRoundTripEntriesThroughTheUstarFormat() throws {
        let content = Data("hello".utf8)
        let entries = [PackEntry(sha256: Hashing.sha256Hex(content), body: try Gzip.compress(content)), PackEntry(sha256: Hashing.sha256Hex("x"), body: Data())]
        let pack = PackWriter.pack(entries)
        XCTAssertEqual(pack.count % 512, 0)
        let read = try PackReader.entries(in: pack)
        XCTAssertEqual(read.map { $0.sha256 }, entries.map { $0.sha256 })
        XCTAssertEqual(try Gzip.decompress(read[0].body, maximumBytes: content.count), content)
    }

    func testShouldRejectATruncatedPack() {
        let pack = PackWriter.pack([PackEntry(sha256: "abc", body: Data(count: 700))])
        XCTAssertThrowsError(try PackReader.entries(in: pack.prefix(600))) { error in
            XCTAssertEqual(error as? PackReader.Failure, .truncated)
        }
    }

    func testShouldIgnoreBytesAfterTheEndOfArchiveBlocks() throws {
        let pack = PackWriter.pack([PackEntry(sha256: "abc", body: Data("x".utf8))]) + Data("trailing".utf8)
        XCTAssertEqual(try PackReader.entries(in: pack).map { $0.sha256 }, ["abc"])
    }

    func testShouldRefuseAnEntryWithANegativeSize() {
        var pack = PackWriter.pack([PackEntry(sha256: "abc", body: Data(count: 700))])
        pack.replaceSubrange(124..<135, with: Data("-0000001000".utf8))
        XCTAssertThrowsError(try PackReader.entries(in: pack))
    }

    func testShouldDecompressGzipAndRejectGarbage() throws {
        let content = Data((0..<10_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(content), maximumBytes: content.count), content)
        XCTAssertThrowsError(try Gzip.decompress(Data("not gzip".utf8), maximumBytes: 100))
    }

    func testShouldRefuseToInflatePastTheMaximum() throws {
        let content = Data(count: 1_000_000)
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(content), maximumBytes: content.count), content)
        XCTAssertThrowsError(try Gzip.decompress(try Gzip.compress(content), maximumBytes: content.count - 1)) { error in
            XCTAssertEqual(error as? Gzip.Failure, .tooLarge(maximumBytes: content.count - 1))
        }
    }
}
