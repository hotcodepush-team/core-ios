import XCTest
@testable import HotCodePushProtocol

/// The protocol's fixture suite, read from the installed `@hotcodepush/protocol` package: the same cases every core runs.
final class FixtureTests: XCTestCase {
    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("node_modules/@hotcodepush/protocol/fixtures", isDirectory: true)

    private struct EvaluationFile: Decodable {
        let description: String
        let cases: [EvaluationCase]
    }

    private struct EvaluationCase: Decodable {
        let name: String
        let index: ChannelIndex
        let device: FixtureDevice
        let expected: Expected
        let verdicts: [ExpectedVerdict]?
    }

    private struct FixtureDevice: Decodable {
        struct CurrentRelease: Decodable {
            let id: String
            let number: Int
        }

        let appliedIndexSequence: Int?
        let attributes: [String: String]
        let binaryBuild: String
        let binaryVersion: String
        let builtAt: Date
        let currentRelease: CurrentRelease?
        let deviceId: String
        let failedBundleIds: [String]
        let fingerprint: String?
        let osVersion: String
        let reportedAt: Date?
        let runtimeVersion: String?

        var deviceInfo: DeviceInfo {
            return DeviceInfo(appliedIndexSequence: appliedIndexSequence, attributes: attributes, binaryBuild: binaryBuild, binaryVersion: binaryVersion, builtAt: builtAt, currentRelease: currentRelease.map { Release(id: $0.id, number: $0.number, bundleId: "", bundleVersion: "", isMandatory: false) }, deviceId: deviceId, failedBundleIds: failedBundleIds, fingerprint: fingerprint, osVersion: osVersion, reportedAt: reportedAt, runtimeVersion: runtimeVersion)
        }
    }

    private struct Expected: Decodable, Equatable {
        let status: String
        let releaseId: String?
        let isMandatory: Bool?
        let reason: String?
        let condition: String?

        init(_ evaluation: Evaluation) {
            switch evaluation {
            case .upToDate(let release):
                self.init(status: "UP_TO_DATE", releaseId: release?.id, isMandatory: nil, reason: nil, condition: nil)
            case .available(let release, let isMandatory):
                self.init(status: "AVAILABLE", releaseId: release.id, isMandatory: isMandatory, reason: nil, condition: nil)
            case .skipped(let release, let reason, let condition):
                self.init(status: "SKIPPED", releaseId: release?.id, isMandatory: nil, reason: reason.rawValue, condition: condition?.rawValue)
            }
        }

        init(status: String, releaseId: String?, isMandatory: Bool?, reason: String?, condition: String?) {
            self.status = status
            self.releaseId = releaseId
            self.isMandatory = isMandatory
            self.reason = reason
            self.condition = condition
        }
    }

    private struct ExpectedVerdict: Decodable, Equatable {
        let releaseId: String
        let isEligible: Bool
        let reason: String?
        let condition: String?

        init(_ verdict: ReleaseVerdict) {
            self.init(releaseId: verdict.release.id, isEligible: verdict.isEligible, reason: verdict.reason?.rawValue, condition: verdict.condition?.rawValue)
        }

        init(releaseId: String, isEligible: Bool, reason: String?, condition: String?) {
            self.releaseId = releaseId
            self.isEligible = isEligible
            self.reason = reason
            self.condition = condition
        }
    }

    private struct VersionRangeFile: Decodable {
        struct Case: Decodable {
            let range: String
            let version: String
            let satisfied: Bool?
        }
        let cases: [Case]
    }

    private struct RolloutFile: Decodable {
        struct Case: Decodable {
            let deviceId: String
            let releaseId: String
            let bucket: Int
        }
        let cases: [Case]
    }

    private struct ResourceFilesFile: Decodable {
        struct Case: Decodable {
            let name: String
            let resourceFile: Configuration
            let embeddedBundleManifest: EmbeddedBundleManifest
        }
        let cases: [Case]
    }

    private struct SignaturesFile: Decodable {
        struct SignedManifest: Decodable {
            let manifest: String
            let signature: Signature?
        }
        struct Case: Decodable {
            let name: String
            let envelope: SignedManifest
            let isValid: Bool
        }
        let manifests: [Case]
    }

    private struct BoundsFile: Decodable {
        let deviceConditionMaxHashedIds: Int
        let releaseMaxConditions: Int
    }

    private struct PackFile: Decodable {
        struct Entry: Decodable {
            let content: String
            let sha256: String
        }
        struct RefusedPack: Decodable {
            let name: String
            let packBase64: String
        }
        let entries: [Entry]
        let packBase64: String
        let packSha256: String
        let refusedPacks: [RefusedPack]
    }

    private func load<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        let url = FixtureTests.fixturesDirectory.appendingPathComponent(path)
        return try Json.decoder.decode(T.self, from: try Data(contentsOf: url))
    }

    /// The cases of one list of the wire-rules file, each document re-serialized on its own so a refused one fails only its own decode.
    private func wireRulesCases(listed key: String, holding document: String) throws -> [(name: String, data: Data)] {
        let url = FixtureTests.fixturesDirectory.appendingPathComponent("wire-rules.json")
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(file[key] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty, key)
        return try cases.map { (try XCTUnwrap($0["name"] as? String), try JSONSerialization.data(withJSONObject: try XCTUnwrap($0[document]))) }
    }

    private func assertAccepted<T: Decodable>(_ type: T.Type, listed key: String, holding document: String) throws {
        for testCase in try wireRulesCases(listed: key, holding: document) {
            XCTAssertNoThrow(try Json.decoder.decode(T.self, from: testCase.data), "\(key): \(testCase.name)")
        }
    }

    private func assertRefused<T: Decodable>(_ type: T.Type, listed key: String, holding document: String) throws {
        for testCase in try wireRulesCases(listed: key, holding: document) {
            XCTAssertThrowsError(try Json.decoder.decode(T.self, from: testCase.data), "\(key): \(testCase.name)")
        }
    }

    func testShouldMatchEveryEvaluationFixture() throws {
        let directory = FixtureTests.fixturesDirectory.appendingPathComponent("evaluation")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty, "no evaluation fixtures at \(directory.path)")
        var count = 0
        var verdictCount = 0
        for file in files {
            let fixture = try load("evaluation/\(file)", as: EvaluationFile.self)
            for testCase in fixture.cases {
                let evaluation = Evaluator.evaluation(of: testCase.index, device: testCase.device.deviceInfo)
                XCTAssertEqual(Expected(evaluation.outcome), testCase.expected, "\(file): \(testCase.name)")
                count += 1
                if let verdicts = testCase.verdicts {
                    XCTAssertEqual(evaluation.verdicts.map(ExpectedVerdict.init), verdicts, "\(file): \(testCase.name)")
                    verdictCount += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 50)
        XCTAssertGreaterThanOrEqual(verdictCount, 16)
    }

    func testShouldAcceptEveryAcceptedWireRulesFixture() throws {
        try assertAccepted(ChannelIndex.self, listed: "acceptedIndexes", holding: "index")
        try assertAccepted(BundleManifest.self, listed: "acceptedManifests", holding: "manifest")
        try assertAccepted(ManifestEnvelope.self, listed: "acceptedEnvelopes", holding: "envelope")
    }

    func testShouldRefuseEveryRefusedWireRulesFixture() throws {
        try assertRefused(ChannelIndex.self, listed: "refusedIndexes", holding: "index")
        try assertRefused(BundleManifest.self, listed: "refusedManifests", holding: "manifest")
        try assertRefused(ManifestEnvelope.self, listed: "refusedEnvelopes", holding: "envelope")
    }

    func testShouldMatchEveryVersionRangeFixture() throws {
        for testCase in try load("version-ranges.json", as: VersionRangeFile.self).cases {
            let version = try XCTUnwrap(VersionRange.parseVersion(testCase.version))
            XCTAssertEqual(VersionRange.isVersionInRange(version, testCase.range), testCase.satisfied, "\(testCase.version) in \(testCase.range)")
        }
    }

    func testShouldMatchEveryRolloutBucketFixture() throws {
        for testCase in try load("rollout-buckets.json", as: RolloutFile.self).cases {
            XCTAssertEqual(Hashing.rolloutBucket(deviceId: testCase.deviceId, releaseId: testCase.releaseId), testCase.bucket, "\(testCase.deviceId) \(testCase.releaseId)")
        }
    }

    func testShouldReadEveryResourceFileFixture() throws {
        let cases = try load("resource-files.json", as: ResourceFilesFile.self).cases
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            XCTAssertEqual(testCase.resourceFile.embeddedBundleManifest, testCase.embeddedBundleManifest, testCase.name)
        }
    }

    /// Every signed manifest of the suite is a manifest this reader decodes, its signature in the wire's form; whether the signature verifies is the signing milestone's.
    func testShouldDecodeTheManifestOfEverySignatureFixture() throws {
        let cases = try load("signatures.json", as: SignaturesFile.self).manifests
        XCTAssertGreaterThan(cases.count, 5)
        for testCase in cases {
            XCTAssertNoThrow(try Json.decoder.decode(BundleManifest.self, from: Data(testCase.envelope.manifest.utf8)), testCase.name)
        }
    }

    /// The bounds are the writer's: a reader takes a release with more conditions, and a device condition with more ids, than the API accepts.
    func testShouldReadPastTheWriterBoundsFixture() throws {
        let bounds = try load("bounds.json", as: BoundsFile.self)
        let hashedIds = (0...bounds.deviceConditionMaxHashedIds).map { Hashing.sha256Hex("device-\($0)") }
        let conditions = (0...bounds.releaseMaxConditions).map { _ in Condition.device(hashedIds: hashedIds) }
        let release = IndexRelease(id: "r1", number: 1, createdAt: Fixture.builtAt, conditions: conditions, bundleId: "b1", bundleVersion: "1.0.0", manifestUrl: "\(Fixture.filesBaseUrl)/manifest.json", manifestSha256: Hashing.sha256Hex("manifest"), sizeBytes: 1)
        let index = Fixture.index(sequence: 1, releases: [release])
        XCTAssertEqual(try Json.decoder.decode(ChannelIndex.self, from: Json.encoder.encode(index)), index)
    }

    func testShouldReadAndWriteThePackFixture() throws {
        let fixture = try load("packs.json", as: PackFile.self)
        let pack = try XCTUnwrap(Data(base64Encoded: fixture.packBase64))
        XCTAssertEqual(Hashing.sha256Hex(pack), fixture.packSha256)
        let entries = try PackReader.entries(in: pack)
        XCTAssertEqual(entries.map { $0.sha256 }, fixture.entries.map { $0.sha256 })
        for (entry, expected) in zip(entries, fixture.entries) {
            XCTAssertEqual(entry.body, Data(expected.content.utf8))
            XCTAssertEqual(Hashing.sha256Hex(entry.body), expected.sha256)
        }
        XCTAssertEqual(PackWriter.pack(entries), pack)
    }

    func testShouldRefuseEveryRefusedPackFixture() throws {
        let fixture = try load("packs.json", as: PackFile.self)
        XCTAssertFalse(fixture.refusedPacks.isEmpty)
        for refused in fixture.refusedPacks {
            let pack = try XCTUnwrap(Data(base64Encoded: refused.packBase64), refused.name)
            XCTAssertThrowsError(try PackReader.entries(in: pack), refused.name) { error in
                XCTAssertTrue(error is PackReader.Failure, refused.name)
            }
        }
    }
}
