import XCTest
@testable import HotCodePushProtocol

final class WireTypesTests: XCTestCase {
    private let sha256 = Hashing.sha256Hex("content")

    func testShouldRefuseAManifestWhoseBundleIdIsNotAnIdentifier() {
        for bundleId in ["../..", "", "bundles/b1", String(repeating: "b", count: 65), "bündle"] {
            XCTAssertThrowsError(try decodeManifest(bundleId: bundleId, path: "index.html", sha256: sha256), bundleId)
        }
    }

    func testShouldRefuseAManifestPathThatClimbsOutOfItsDirectory() {
        for path in ["../escape.html", "assets/../../escape.html", "/etc/hosts", "assets//app.js", "./index.html", "assets\\..\\escape.html", "index\u{0}.html", ""] {
            XCTAssertThrowsError(try decodeManifest(bundleId: "b1", path: path, sha256: sha256), path)
        }
    }

    func testShouldRefuseAManifestFileHashThatIsNotALowercaseSha256() {
        for hash in ["../../Documents/escape", sha256.uppercased(), String(sha256.dropLast())] {
            XCTAssertThrowsError(try decodeManifest(bundleId: "b1", path: "index.html", sha256: hash), hash)
        }
    }

    func testShouldRefuseAnIndexReleaseWhoseIdsAreNotIdentifiers() {
        XCTAssertThrowsError(try decodeIndexRelease(id: "../r1", bundleId: "b1"))
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "../.."))
    }

    func testShouldRefuseAnIndexReleaseWhoseManifestHashIsNotALowercaseSha256() {
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "b1", manifestSha256: sha256.uppercased()))
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "b1", manifestSha256: "../escape"))
    }

    func testShouldAcceptTheIdsAndPathsTheApiWrites() throws {
        let bundleId = "0f8fad5b-d9cb-469f-a165-70867728950e"
        for path in ["index.html", "assets/index-a1b2c3.js", ".well-known/assetlinks.json", "assets/..hidden"] {
            XCTAssertEqual(try decodeManifest(bundleId: bundleId, path: path, sha256: sha256).files.first?.path, path)
        }
        XCTAssertEqual(try decodeIndexRelease(id: "1c6e2a3b-7f4d-4e1a-9b2c-3d4e5f6a7b8c", bundleId: bundleId).bundleId, bundleId)
    }

    private func decodeManifest(bundleId: String, path: String, sha256: String) throws -> BundleManifest {
        let manifest = BundleManifest(bundleId: bundleId, appId: Fixture.appId, version: "1.0.0", createdAt: Fixture.builtAt, files: [.init(path: path, sha256: sha256, sizeBytes: 7)])
        return try Json.decoder.decode(BundleManifest.self, from: Json.encoder.encode(manifest))
    }

    private func decodeIndexRelease(id: String, bundleId: String, manifestSha256: String? = nil) throws -> IndexRelease {
        let release = IndexRelease(id: id, number: 1, createdAt: Fixture.builtAt, bundleId: bundleId, bundleVersion: "1.0.0", manifestUrl: "\(Fixture.filesBaseUrl)/manifest.json", manifestSha256: manifestSha256 ?? sha256, sizeBytes: 7)
        return try Json.decoder.decode(IndexRelease.self, from: Json.encoder.encode(release))
    }
}
