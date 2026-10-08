import XCTest
@testable import HotCodePushCore

final class WireTypesTests: XCTestCase {
    private let sha256 = Hashing.sha256Hex("content")

    func testShouldRefuseAnEnvelopeWhoseBundleIdIsNotAnIdentifier() {
        for bundleId in ["../..", "", "bundles/b1", String(repeating: "b", count: 65), "bündle"] {
            XCTAssertThrowsError(try decodeEnvelope(bundleId: bundleId), bundleId)
        }
    }

    func testShouldRefuseAManifestPathThatClimbsOutOfItsDirectory() {
        for path in ["../escape.html", "assets/../../escape.html", "/etc/hosts", "assets//app.js", "./index.html", "assets\\..\\escape.html", "index\u{0}.html", "", "../\u{301}escape.html"] {
            XCTAssertThrowsError(try decodeManifest(path: path, sha256: sha256), path)
        }
    }

    func testShouldRefuseAManifestFileHashThatIsNotALowercaseSha256() {
        for hash in ["../../Documents/escape", sha256.uppercased(), String(sha256.dropLast())] {
            XCTAssertThrowsError(try decodeManifest(path: "index.html", sha256: hash), hash)
        }
    }

    func testShouldReadAManifestStoredWhileBundlesCarriedPatches() throws {
        let stored = "{\"appId\":\"a1\",\"bundleVersion\":\"1.0.0\",\"files\":[{\"path\":\"index.html\",\"sha256\":\"\(sha256)\",\"sizeBytes\":7}],\"fingerprint\":null,\"keyId\":null,\"patches\":[],\"platforms\":[\"ios\"]}"
        let manifest = try Json.decoder.decode(BundleManifest.self, from: Data(stored.utf8))
        XCTAssertEqual(manifest, BundleManifest(appId: "a1", bundleVersion: "1.0.0", files: [.init(path: "index.html", sha256: sha256, sizeBytes: 7)], platforms: ["ios"]))
    }

    func testShouldRefuseAnIndexReleaseWhoseIdsAreNotIdentifiers() {
        XCTAssertThrowsError(try decodeIndexRelease(id: "../r1", bundleId: "b1"))
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "../.."))
    }

    func testShouldRefuseAnIndexReleaseWhoseManifestHashIsNotALowercaseSha256() {
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "b1", manifestSha256: sha256.uppercased()))
        XCTAssertThrowsError(try decodeIndexRelease(id: "r1", bundleId: "b1", manifestSha256: "../escape"))
    }

    func testShouldReadTimestampsInUtcOnlyAndToTheMillisecond() {
        XCTAssertNil(Iso8601.parse("2026-09-29T12:00:00.000+02:00"))
        XCTAssertNil(Iso8601.parse("2026-09-29T10:00:00"))
        XCTAssertEqual(Iso8601.parse("2026-09-29T10:00:00.5Z"), Iso8601.parse("2026-09-29T10:00:00.500Z"))
        XCTAssertEqual(Iso8601.parse("2026-09-29T10:00:00.1234567Z"), Iso8601.parse("2026-09-29T10:00:00.123Z"))
        XCTAssertEqual(Iso8601.parse("2026-09-29T10:00:00Z").map(Iso8601.format), "2026-09-29T10:00:00.000Z")
    }

    func testShouldAcceptTheIdsAndPathsTheApiWrites() throws {
        let bundleId = "0f8fad5b-d9cb-469f-a165-70867728950e"
        for path in ["index.html", "assets/index-a1b2c3.js", ".well-known/assetlinks.json", "assets/..hidden"] {
            XCTAssertEqual(try decodeManifest(path: path, sha256: sha256).files.first?.path, path)
        }
        XCTAssertEqual(try decodeEnvelope(bundleId: bundleId).bundleId, bundleId)
        XCTAssertEqual(try decodeIndexRelease(id: "1c6e2a3b-7f4d-4e1a-9b2c-3d4e5f6a7b8c", bundleId: bundleId).bundleId, bundleId)
    }

    func testShouldRefuseAResourceFileWhoseAppIdOrEmbeddedBundleIdIsNotAnIdentifier() throws {
        let configuration = try JSONSerialization.jsonObject(with: Json.encoder.encode(Fixture.configuration())) as? [String: Any]
        for (key, value) in [("appId", "a1/../a2"), ("embeddedBundleId", "../b0")] {
            var json = try XCTUnwrap(configuration)
            json[key] = value
            XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)), key)
        }
    }

    func testShouldRefuseAResourceFileWhoseDurationIsBelowItsFloor() throws {
        let configuration = try JSONSerialization.jsonObject(with: Json.encoder.encode(Fixture.configuration())) as? [String: Any]
        for (key, seconds) in [("checkIntervalSeconds", 59.0), ("checkIntervalSeconds", -900), ("readyTimeoutSeconds", 0.5), ("readyTimeoutSeconds", -10), ("applyOnResumeAfterSeconds", -1)] {
            var json = try XCTUnwrap(configuration)
            json[key] = seconds
            XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)), "\(key) \(seconds)")
        }
    }

    func testShouldReadEveryDurationAtItsFloorAsWritten() throws {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Json.encoder.encode(Fixture.configuration())) as? [String: Any])
        json["checkIntervalSeconds"] = 60
        json["readyTimeoutSeconds"] = 1
        json["applyOnResumeAfterSeconds"] = 0
        let configuration = try Configuration.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(configuration.checkIntervalSeconds, 60)
        XCTAssertEqual(configuration.readyTimeoutSeconds, 1)
        XCTAssertEqual(configuration.applyOnResumeAfterSeconds, 0)
    }

    func testShouldRefuseAStoredReleaseWhoseIdsAreNotIdentifiers() throws {
        let stored = Data(#"{"id":"r1","number":1,"bundleId":"../b1","bundleVersion":"1.0.0","isMandatory":false}"#.utf8)
        XCTAssertThrowsError(try Json.decoder.decode(Release.self, from: stored))
    }

    func testShouldRefuseAResourceFileWhoseHostIsNotHttpOrHttps() throws {
        let configuration = try JSONSerialization.jsonObject(with: Json.encoder.encode(Fixture.configuration())) as? [String: Any]
        var json = try XCTUnwrap(configuration)
        json["filesBaseUrl"] = "file:///private/var/www"
        XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)))
    }

    private func decodeManifest(path: String, sha256: String) throws -> BundleManifest {
        let manifest = BundleManifest(appId: Fixture.appId, bundleVersion: "1.0.0", files: [.init(path: path, sha256: sha256, sizeBytes: 7)], platforms: ["ios"])
        return try Json.decoder.decode(BundleManifest.self, from: Json.encoder.encode(manifest))
    }

    private func decodeEnvelope(bundleId: String) throws -> ManifestEnvelope {
        let envelope = ManifestEnvelope(bundleId: bundleId, createdAt: Fixture.builtAt, manifest: "{}", pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 1))
        return try Json.decoder.decode(ManifestEnvelope.self, from: Json.encoder.encode(envelope))
    }

    private func decodeIndexRelease(id: String, bundleId: String, manifestSha256: String? = nil) throws -> IndexRelease {
        let release = IndexRelease(id: id, number: 1, createdAt: Fixture.builtAt, bundleId: bundleId, bundleVersion: "1.0.0", manifestUrl: "\(Fixture.filesBaseUrl)/manifest.json", manifestSha256: manifestSha256 ?? sha256, sizeBytes: 7)
        return try Json.decoder.decode(IndexRelease.self, from: Json.encoder.encode(release))
    }
}
