import XCTest
@testable import HotCodePushCore

/// FreeBSD's bspatch on the patches in `Tests/BspatchFixtures`: a patch arrives unsigned, so a hostile
/// one must end in an error or in bytes the hash check refuses, never in a read or write outside a buffer.
final class BspatchTests: XCTestCase {
    private static let controlLengthOffset = 8
    private static let diffLengthOffset = 16
    private static let newSizeOffset = 24

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hotcodepush-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testShouldApplyAPatchMadeByBsdiff() throws {
        let new = try apply(fixture("valid.patch"))
        XCTAssertEqual(try Data(contentsOf: new), try fixture("new.bin"))
    }

    func testShouldRefuseThePatchAndLeaveNoFileWhenItIsCutInsideABlock() throws {
        let patch = try fixture("valid.patch")
        assertRefused(patch.prefix(patch.count - 40), as: .corruptPatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new").path))
    }

    func testShouldRefuseThePatchWhenItIsCutInsideTheHeader() throws {
        assertRefused(try fixture("valid.patch").prefix(20), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenTheMagicIsWrong() throws {
        var patch = try fixture("valid.patch")
        patch.replaceSubrange(0..<8, with: Data("BSDIFF41".utf8))
        assertRefused(patch, as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenTheHeaderCarriesANegativeControlLength() throws {
        assertRefused(try settingOffset(-1, at: Self.controlLengthOffset, in: fixture("valid.patch")), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenTheHeaderCarriesANegativeNewSize() throws {
        assertRefused(try settingOffset(-1, at: Self.newSizeOffset, in: fixture("valid.patch")), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenTheHeaderCarriesAHugeDiffLength() throws {
        assertRefused(try settingOffset(Int64.max, at: Self.diffLengthOffset, in: fixture("valid.patch")), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenTheHeaderCarriesANewSizeAboveTheBound() throws {
        let patch = try fixture("valid.patch")
        let newSize = try fixture("new.bin").count
        assertRefused(patch, maximumBytes: newSize - 1, as: .corruptPatch)
    }

    func testShouldFailWhenTheHeaderCarriesANewSizeNoMemoryHolds() throws {
        assertRefused(try settingOffset(Int64.max / 4, at: Self.newSizeOffset, in: fixture("valid.patch")), maximumBytes: Int.max, as: .outOfMemory)
    }

    func testShouldRefuseThePatchWhenAControlTripleCarriesALengthPast32Bits() throws {
        assertRefused(try fixture("length-past-32-bits.patch"), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenAControlTripleWritesTheDiffPastTheNewFile() throws {
        assertRefused(try fixture("diff-past-new-file.patch"), as: .corruptPatch)
    }

    func testShouldRefuseThePatchWhenAControlTripleWritesTheExtraPastTheNewFile() throws {
        assertRefused(try fixture("extra-past-new-file.patch"), as: .corruptPatch)
    }

    func testShouldReadNothingWhenAControlTripleSeeksBeforeTheOldFile() throws {
        XCTAssertEqual(try Data(contentsOf: apply(fixture("seek-before-old-file.patch"))), Data(count: 32))
    }

    func testShouldReadNothingWhenAControlTripleSeeksPastTheOldFile() throws {
        XCTAssertEqual(try Data(contentsOf: apply(fixture("seek-past-old-file.patch"))), Data(count: 32))
    }

    func testShouldFailWhenTheOldFileIsMissing() throws {
        let patch = directory.appendingPathComponent("patch")
        try fixture("valid.patch").write(to: patch)
        XCTAssertThrowsError(try Bspatch.apply(patch, to: directory.appendingPathComponent("missing"), writingTo: directory.appendingPathComponent("new"), maximumBytes: 1_000_000)) { error in
            XCTAssertEqual(error as? Bspatch.Failure, .ioError)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        return try BspatchFixture.data(name)
    }

    /// Applies the patch to `old.bin` and returns where the new file is.
    private func apply(_ patch: Data, maximumBytes: Int = 1_000_000) throws -> URL {
        let patchFile = directory.appendingPathComponent("patch")
        let new = directory.appendingPathComponent("new")
        try patch.write(to: patchFile)
        try Bspatch.apply(patchFile, to: BspatchFixture.url("old.bin"), writingTo: new, maximumBytes: maximumBytes)
        return new
    }

    private func assertRefused(_ patch: Data, maximumBytes: Int = 1_000_000, as expected: Bspatch.Failure, line: UInt = #line) {
        XCTAssertThrowsError(try apply(patch, maximumBytes: maximumBytes), line: line) { error in
            XCTAssertEqual(error as? Bspatch.Failure, expected, line: line)
        }
    }

    /// The patch with one header field set the way bsdiff writes an offset: eight bytes little-endian, the sign in the top bit.
    private func settingOffset(_ value: Int64, at offset: Int, in patch: Data) -> Data {
        var bytes = withUnsafeBytes(of: value.magnitude.littleEndian) { Array($0) }
        if value < 0 { bytes[7] |= 0x80 }
        var patched = patch
        patched.replaceSubrange(offset..<(offset + 8), with: bytes)
        return patched
    }
}

/// The committed bsdiff 4.3 patch with its old and new file, and the hostile patches `make-patches.sh` writes beside them.
enum BspatchFixture {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BspatchFixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        return directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        return try Data(contentsOf: url(name))
    }
}
