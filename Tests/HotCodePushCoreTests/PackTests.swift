import XCTest
@testable import HotCodePushCore

final class PackTests: XCTestCase {
    private let fromSha256 = Hashing.sha256Hex("from")
    private let toSha256 = Hashing.sha256Hex("to")

    func testShouldRoundTripEntriesThroughTheUstarFormat() throws {
        let content = Data("hello".utf8)
        let entries: [PackEntry] = [.file(sha256: Hashing.sha256Hex(content), body: try Gzip.compress(content)), .file(sha256: Hashing.sha256Hex("x"), body: Data())]
        let pack = PackWriter.pack(entries)
        XCTAssertEqual(pack.count % 512, 0)
        let read = try PackReader.entries(in: pack)
        XCTAssertEqual(read, entries)
        guard case .file(_, let body) = read[0] else { return XCTFail("not a file entry") }
        XCTAssertEqual(try Gzip.decompress(body, maximumBytes: content.count), content)
    }

    func testShouldReadAPatchEntryNamedThroughThePrefix() throws {
        let entry = PackEntry.patch(fromSha256: fromSha256, toSha256: toSha256, body: Data("BSDIFF40".utf8))
        XCTAssertEqual(try PackReader.entries(in: PackWriter.pack([entry])), [entry])
    }

    func testShouldSkipAnEntryOfAnotherNameWithItsBody() throws {
        var pack = Data()
        PackWriter.append(prefix: "", name: "notes.txt", body: Data(count: 700), to: &pack)
        PackWriter.append(prefix: "future/\(fromSha256)", name: toSha256, body: Data(count: 10), to: &pack)
        PackWriter.append(prefix: "patches/\(fromSha256)", name: "\(toSha256)/extra", body: Data(count: 10), to: &pack)
        let kept = PackEntry.file(sha256: toSha256, body: Data("x".utf8))
        pack.append(PackWriter.pack([kept]))
        XCTAssertEqual(try PackReader.entries(in: pack), [kept])
    }

    func testShouldSkipAnEntryNamedByAnUppercaseHash() throws {
        var pack = Data()
        PackWriter.append(prefix: "", name: toSha256.uppercased(), body: Data("x".utf8), to: &pack)
        pack.append(Data(count: 1024))
        XCTAssertEqual(try PackReader.entries(in: pack), [])
    }

    func testShouldRejectATruncatedPack() {
        let pack = PackWriter.pack([.file(sha256: toSha256, body: Data(count: 700))])
        XCTAssertThrowsError(try PackReader.entries(in: pack.prefix(600))) { error in
            XCTAssertEqual(error as? PackReader.Failure, .truncated)
        }
    }

    func testShouldRejectATruncatedPackWhenTheCutEntryIsSkipped() {
        var pack = Data()
        PackWriter.append(prefix: "", name: "notes.txt", body: Data(count: 700), to: &pack)
        XCTAssertThrowsError(try PackReader.entries(in: pack.prefix(600))) { error in
            XCTAssertEqual(error as? PackReader.Failure, .truncated)
        }
    }

    func testShouldIgnoreBytesAfterTheEndOfArchiveBlocks() throws {
        let entry = PackEntry.file(sha256: toSha256, body: Data("x".utf8))
        let pack = PackWriter.pack([entry]) + Data("trailing".utf8)
        XCTAssertEqual(try PackReader.entries(in: pack), [entry])
    }

    func testShouldRefuseAnEntryWithANegativeSize() {
        var pack = PackWriter.pack([.file(sha256: toSha256, body: Data(count: 700))])
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
