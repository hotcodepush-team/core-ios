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
            let embeddedBundleManifest: BundleManifest
        }
        let cases: [Case]
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

    func testShouldMatchEveryEvaluationFixture() throws {
        let directory = FixtureTests.fixturesDirectory.appendingPathComponent("evaluation")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty, "no evaluation fixtures at \(directory.path)")
        var count = 0
        for file in files {
            let fixture = try load("evaluation/\(file)", as: EvaluationFile.self)
            for testCase in fixture.cases {
                let actual = Expected(Evaluator.evaluate(testCase.index, device: testCase.device.deviceInfo))
                XCTAssertEqual(actual, testCase.expected, "\(file): \(testCase.name)")
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 50)
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
