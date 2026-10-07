import XCTest
@testable import HotCodePushCore

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

        var deviceInfo: DeviceInfo {
            return DeviceInfo(attributes: attributes, binaryBuild: binaryBuild, binaryVersion: binaryVersion, builtAt: builtAt, currentRelease: currentRelease.map { Release(id: $0.id, number: $0.number, bundleId: "", bundleVersion: "", isMandatory: false) }, deviceId: deviceId, failedBundleIds: failedBundleIds, fingerprint: fingerprint, osVersion: osVersion, reportedAt: reportedAt)
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
            let embeddedBundleManifest: EmbeddedBundleManifest?
        }
        let cases: [Case]
    }

    private struct SignaturesFile: Decodable {
        struct SignedManifest: Decodable {
            let manifest: String
            let signature: Signature?

            var envelope: ManifestEnvelope {
                return ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: manifest, signature: signature, pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
            }
        }
        struct DevicePublicKeys: Decodable {
            let ios: [DevicePublicKey]
        }
        struct Case: Decodable {
            let name: String
            let envelope: SignedManifest
            let devicePublicKeys: DevicePublicKeys
            let isValid: Bool
        }
        let manifests: [Case]
    }

    private struct ConfiguredHostsFile: Decodable {
        struct Case: Decodable {
            let name: String
            let filesBaseUrl: String?
            let updatesBaseUrl: String?
            let url: String
            let isOnConfiguredHost: Bool
        }
        let cases: [Case]
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

    private struct PackEntriesFile: Decodable {
        struct File: Decodable {
            let contentBase64: String
            let sha256: String
        }
        struct Entry: Decodable {
            let bodyBase64: String
            let fromSha256: String?
            let sha256: String?
            let toSha256: String?
            let type: String

            func packEntry() throws -> PackEntry {
                let body = try XCTUnwrap(Data(base64Encoded: bodyBase64))
                if type == "file" {
                    return .file(sha256: try XCTUnwrap(sha256), body: body)
                }
                return .patch(fromSha256: try XCTUnwrap(fromSha256), toSha256: try XCTUnwrap(toSha256), body: body)
            }
        }
        struct Pack: Decodable {
            let entries: [Entry]
            let packBase64: String
        }
        struct PatchEntry: Decodable {
            let bodyBase64: String
            let fromSha256: String
            let toSha256: String

            func packEntry() throws -> PackEntry {
                return .patch(fromSha256: fromSha256, toSha256: toSha256, body: try XCTUnwrap(Data(base64Encoded: bodyBase64)))
            }
        }
        struct PatchCase: Decodable {
            let name: String
            let heldSha256s: [String]
            let manifestFiles: [BundleManifest.File]
            let patchEntry: PatchEntry
            let outcome: String
        }
        let files: [File]
        let deltaPack: Pack
        let skippedEntryPack: Pack
        let patchCases: [PatchCase]
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
        XCTAssertGreaterThanOrEqual(verdictCount, 15)
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

    /// A production build names no host, which the fixture writes as `null`: the configuration's defaults apply.
    func testShouldMatchEveryConfiguredHostsFixture() throws {
        let cases = try load("configured-hosts.json", as: ConfiguredHostsFile.self).cases
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let configuration = Fixture.configuration(filesBaseUrl: testCase.filesBaseUrl, updatesBaseUrl: testCase.updatesBaseUrl)
            XCTAssertEqual(configuration.isOnConfiguredHost(testCase.url), testCase.isOnConfiguredHost, testCase.name)
        }
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
        let withoutChannel = cases.filter { $0.resourceFile.channelId == nil && $0.resourceFile.embeddedBundleManifest != nil }
        XCTAssertEqual(withoutChannel.count, 1, "the suite carries one build without a channel")
        XCTAssertTrue(withoutChannel.allSatisfy { $0.name.contains("without a channel") && $0.resourceFile.embeddedBundleId == nil })
        let withoutEmbeddedBundle = cases.filter { $0.resourceFile.embeddedBundleManifest == nil }
        XCTAssertEqual(withoutEmbeddedBundle.count, 1, "the suite carries one build without an embedded bundle")
        XCTAssertTrue(withoutEmbeddedBundle.allSatisfy { $0.name.contains("without an embedded bundle") && $0.resourceFile.embeddedBundleId == nil })
    }

    /// Every signed manifest of the suite is a manifest this reader decodes, its signature in the wire's form.
    func testShouldDecodeTheManifestOfEverySignatureFixture() throws {
        let cases = try load("signatures.json", as: SignaturesFile.self).manifests
        XCTAssertGreaterThan(cases.count, 5)
        for testCase in cases {
            XCTAssertNoThrow(try Json.decoder.decode(BundleManifest.self, from: Data(testCase.envelope.manifest.utf8)), testCase.name)
        }
    }

    /// The suite's verdicts, case for case, against the keys as an iOS resource file carries them.
    func testShouldMatchEverySignatureFixture() throws {
        let cases = try load("signatures.json", as: SignaturesFile.self).manifests
        var verified = 0
        for testCase in cases {
            let isValid = (try? Signatures.verifyManifestSignature(testCase.envelope.envelope, publicKeys: testCase.devicePublicKeys.ios)) != nil
            XCTAssertEqual(isValid, testCase.isValid, testCase.name)
            verified += isValid ? 1 : 0
        }
        XCTAssertGreaterThanOrEqual(verified, 3)
        XCTAssertGreaterThan(cases.count - verified, 5)
    }

    /// The public keys of the iOS resource file are PKCS #1 DER the system imports as they stand.
    func testShouldImportThePublicKeysOfTheIosResourceFileFixture() throws {
        let cases = try load("resource-files.json", as: ResourceFilesFile.self).cases
        let iosBuild = try XCTUnwrap(cases.first { $0.name.contains("iOS build") })
        XCTAssertEqual(iosBuild.resourceFile.publicKeys.count, 2)
        for publicKey in iosBuild.resourceFile.publicKeys {
            let key = try XCTUnwrap(Signatures.importPublicKey(publicKey), publicKey.keyId)
            XCTAssertEqual(SecKeyGetBlockSize(key) * 8, 4096, publicKey.keyId)
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
        XCTAssertEqual(entries, fixture.entries.map { .file(sha256: $0.sha256, body: Data($0.content.utf8)) })
        for expected in fixture.entries {
            XCTAssertEqual(Hashing.sha256Hex(expected.content), expected.sha256)
        }
        XCTAssertEqual(PackWriter.pack(entries), pack)
    }

    func testShouldReadAndWriteTheDeltaPackOfThePackEntriesFixture() throws {
        let fixture = try load("pack-entries.json", as: PackEntriesFile.self).deltaPack
        let pack = try XCTUnwrap(Data(base64Encoded: fixture.packBase64))
        let entries = try PackReader.entries(in: pack)
        XCTAssertEqual(entries, try fixture.entries.map { try $0.packEntry() })
        XCTAssertEqual(PackWriter.pack(entries), pack)
    }

    func testShouldSkipTheUnknownEntryOfThePackEntriesFixture() throws {
        let fixture = try load("pack-entries.json", as: PackEntriesFile.self).skippedEntryPack
        let pack = try XCTUnwrap(Data(base64Encoded: fixture.packBase64))
        XCTAssertEqual(try PackReader.entries(in: pack), try fixture.entries.map { try $0.packEntry() })
    }

    /// Each case's patch entry in a delta pack against the running bundle, the held files in the store and every file of the
    /// manifest on the files host: applied writes the file without fetching it, fallback fetches it, ignored does neither.
    func testShouldMatchEveryPatchCaseOfThePackEntriesFixture() async throws {
        let fixture = try load("pack-entries.json", as: PackEntriesFile.self)
        let contents = try Dictionary(uniqueKeysWithValues: fixture.files.map { ($0.sha256, try XCTUnwrap(Data(base64Encoded: $0.contentBase64))) })
        for patchCase in fixture.patchCases {
            let harness = DownloaderHarness()
            for sha256 in patchCase.heldSha256s {
                try harness.files.writeFile(try XCTUnwrap(contents[sha256]), sha256: sha256)
            }
            for file in patchCase.manifestFiles {
                harness.http.stub(DownloaderHarness.fileUrl(sha256: file.sha256), body: try XCTUnwrap(contents[file.sha256]))
            }
            let delta = PackWriter.pack([try patchCase.patchEntry.packEntry()])
            let release = harness.publish(DownloaderHarness.manifest(files: patchCase.manifestFiles), deltas: ["b1": delta])
            _ = try await harness.download(release, currentBundleId: "b1")
            let toSha256 = patchCase.patchEntry.toSha256
            let isFetched = harness.http.requests.contains { $0.url.absoluteString == DownloaderHarness.fileUrl(sha256: toSha256) }
            switch patchCase.outcome {
            case "applied":
                XCTAssertTrue(harness.files.hasFile(sha256: toSha256), patchCase.name)
                XCTAssertFalse(isFetched, patchCase.name)
            case "fallback":
                XCTAssertTrue(harness.files.hasFile(sha256: toSha256), patchCase.name)
                XCTAssertTrue(isFetched, patchCase.name)
            case "ignored":
                XCTAssertFalse(harness.files.hasFile(sha256: toSha256), patchCase.name)
                XCTAssertFalse(isFetched, patchCase.name)
            default:
                XCTFail("\(patchCase.name): the outcome \(patchCase.outcome) is unknown")
            }
            XCTAssertTrue(harness.files.isComplete(try XCTUnwrap(harness.files.readManifest(bundleId: DownloaderHarness.bundleId)), embedded: harness.embedded), patchCase.name)
        }
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
