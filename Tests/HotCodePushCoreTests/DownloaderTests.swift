import XCTest
@testable import HotCodePushCore

final class DownloaderTests: XCTestCase {
    private let indexHtml = Data("<html>v2</html>".utf8)
    private let appJs = Data("console.log('v2')".utf8)

    func testShouldRefuseAManifestUrlOffTheConfiguredHosts() async {
        let harness = DownloaderHarness()
        let release = harness.publish(DownloaderHarness.bundle(["index.html": indexHtml]).manifest, manifestUrl: "https://elsewhere.test/manifest.json")
        let failure = await harness.downloadFailure(release)
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertTrue(harness.http.requests.isEmpty)
    }

    func testShouldRefuseAPackUrlOffTheConfiguredHosts() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, packUrl: "https://elsewhere.test/pack"))
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertEqual(harness.http.requests.map { $0.url.host }, ["files.test"])
    }

    func testShouldRefuseAManifestPathThatClimbsOutOfTheServedTree() async {
        let harness = DownloaderHarness()
        let failure = await harness.downloadFailure(harness.publish(DownloaderHarness.bundle(["../../escape.html": indexHtml]).manifest))
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertTrue(harness.files.bundleIds().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("escape.html").path))
    }

    func testShouldRefuseAManifestOfAnotherAppBeforeItFetchesItsPack() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let foreign = BundleManifest(appId: "a0000000-0000-4000-8000-0000000000ff", bundleVersion: bundle.manifest.bundleVersion, files: bundle.manifest.files, platforms: ["ios"])
        let failure = await harness.downloadFailure(harness.publish(foreign, pack: bundle.pack))
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldRefuseAManifestThatLeavesOutTheDevicesPlatform() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let android = BundleManifest(appId: Fixture.appId, bundleVersion: bundle.manifest.bundleVersion, files: bundle.manifest.files, platforms: ["android"])
        let failure = await harness.downloadFailure(harness.publish(android, pack: bundle.pack))
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertTrue(harness.files.bundleIds().isEmpty)
    }

    func testShouldInflateAFileOfManyChunksFromThePackStraightIntoTheStore() async throws {
        let harness = DownloaderHarness()
        let large = Data((0..<3_000_000).map { UInt8($0 % 13) })
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "large.bin": large])
        _ = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(large))), large)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path)
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testShouldMoveASingleFileIntoTheStoreOnlyWhenItMatchesItsHash() async throws {
        let harness = DownloaderHarness()
        let large = Data((0..<1_000_000).map { UInt8($0 % 11) })
        let manifest = DownloaderHarness.bundle(["large.bin": large]).manifest
        harness.http.stub(DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(large)), body: large.dropLast() + Data([0xFF]))
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: DownloaderHarness.emptyPack))
        XCTAssertEqual(failure?.reason, .contentMismatched)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(large)))
        harness.http.stub(DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(large)), body: large)
        let outcome = try await harness.download(harness.publish(manifest, pack: DownloaderHarness.emptyPack))
        XCTAssertEqual(outcome.downloadSizeBytes, DownloaderHarness.emptyPack.count + large.count)
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(large)))
    }

    func testShouldRefuseAnEnvelopeNamingAnotherBundle() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, bundleId: "b3"))
        XCTAssertEqual(failure?.reason, .manifestInvalid)
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldFailADownloadThatDoesNotFitInTheFreeSpace() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let manifest = DownloaderHarness.replacingFiles(of: bundle.manifest, with: bundle.manifest.files.map { .init(path: $0.path, sha256: $0.sha256, sizeBytes: Int.max / 4) })
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: bundle.pack))
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldRefuseAPackEntryThatInflatesPastItsFileSize() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let manifest = DownloaderHarness.replacingFiles(of: bundle.manifest, with: bundle.manifest.files.map { .init(path: $0.path, sha256: $0.sha256, sizeBytes: $0.sizeBytes - 1) })
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: bundle.pack))
        XCTAssertEqual(failure?.reason, .contentMismatched)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldRefuseAPackWhoseLengthDiffersFromTheEnvelope() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, packSizeBytes: bundle.pack.count + 1))
        XCTAssertEqual(failure?.reason, .contentMismatched)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path), [])
    }

    func testShouldStoreASingleFileThatIsItselfGzipAsItArrives() async throws {
        let harness = DownloaderHarness()
        let archive = try Gzip.compress(Data("console.log('precompressed')".utf8))
        let manifest = DownloaderHarness.manifest(files: [.init(path: "assets/app.js.gz", sha256: Hashing.sha256Hex(archive), sizeBytes: archive.count)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(archive))", body: archive)
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: DownloaderHarness.emptyPack))
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(archive))), archive)
    }

    func testShouldRefuseAPackEntryThatIsNotGzip() async {
        let harness = DownloaderHarness()
        let pack = PackWriter.pack([indexHtml, appJs].map { PackEntry.file(sha256: Hashing.sha256Hex($0), body: $0) })
        let manifest = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs]).manifest
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: pack))
        XCTAssertEqual(failure?.reason, .contentMismatched)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldApplyAManifestSignedByAListedKey() async throws {
        let key = SigningFixture.keyA
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [SigningFixture.publicKey(of: SigningFixture.keyB), SigningFixture.publicKey(of: key)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, signingKey: key))
        XCTAssertNil(failure)
        XCTAssertEqual(try XCTUnwrap(harness.files.readManifest(bundleId: DownloaderHarness.bundleId)).keyId, SigningFixture.keyId(of: key))
    }

    func testShouldRefuseAnUnsignedManifestWhenTheAppCarriesAPublicKey() async {
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [SigningFixture.publicKey(of: SigningFixture.keyA)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertEqual(failure, .signatureInvalid("The manifest is unsigned and the app accepts only signed manifests"))
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldRefuseAManifestSignedByAKeyTheAppDoesNotList() async {
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [SigningFixture.publicKey(of: SigningFixture.keyA)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, signingKey: SigningFixture.keyB))
        XCTAssertEqual(failure, .signatureInvalid("The manifest is signed by a key the app does not list: \(SigningFixture.keyId(of: SigningFixture.keyB))"))
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldNameTheConfigurationWhenTheSystemCannotImportTheListedKey() async {
        let keyId = SigningFixture.keyId(of: SigningFixture.keyA)
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [DevicePublicKey(der: "AQID", keyId: keyId)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, signingKey: SigningFixture.keyA))
        XCTAssertEqual(failure, .signatureInvalid("The app's configuration is wrong: the system cannot import the public key \(keyId) of the resource file as an RSA key"))
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldApplyAnUnsignedManifestWhenTheAppCarriesNoPublicKey() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertNil(failure)
    }

    func testShouldTakeTheDeltaTheEnvelopeListsWhenTheDeviceHoldingABaseLacksASingleFile() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml])
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .delta)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1")])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldTakeTheFullPackWhenTheDeviceHoldsNoBaseAndLacksASingleFile() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml])
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.packUrl])
    }

    func testShouldAskTheUpdatesHostDirectlyWhenTheEnvelopeListsNoDeltaForTheBase() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: bundle.pack)
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b0": bundle.pack]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .streamed)
        XCTAssertEqual(outcome.downloadSizeBytes, bundle.pack.count)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1")])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(appJs)))
    }

    func testShouldFailTheDownloadWhenTheDeltaTheEnvelopeListsAnswers404() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        harness.http.stub(DownloaderHarness.deltaUrl(baseBundleId: "b1"), status: 404, body: Data())
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: bundle.pack)
        let failure = await harness.downloadFailure(release, baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1")])
    }

    func testShouldFailTheDownloadWhenTheDeltaTheEnvelopeListsAnswersARedirect() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        harness.http.stub(DownloaderHarness.deltaUrl(baseBundleId: "b1"), status: 302, headers: ["Location": DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1")], body: Data())
        let failure = await harness.downloadFailure(release, baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1")])
    }

    func testShouldTakeTheFullPackWhenTheStreamedDeltaRedirects() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), status: 302, headers: ["Location": DownloaderHarness.packUrl], body: Data())
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.http.requests.map { $0.url.absoluteString }.suffix(2), [DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldFetchTheFilesAStreamedDeltaDidNotCarryOneByOne() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: DownloaderHarness.bundle(["app.js": appJs]).pack)
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .streamed)
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
        XCTAssertFalse(harness.http.requests.contains { $0.url.absoluteString == DownloaderHarness.packUrl })
    }

    func testShouldRefuseAStreamedDeltaLargerThanTheFullPack() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: bundle.pack + Data(count: 512))
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack), baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldRefuseASingleFileLargerThanItsSize() async {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count - 1)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: DownloaderHarness.emptyPack))
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldRefuseASingleFileThatDoesNotMatchItsHash() async {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count)])
        harness.http.stub(DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(indexHtml)), body: Data("<html>v3</html>".utf8))
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: DownloaderHarness.emptyPack))
        XCTAssertEqual(failure?.reason, .contentMismatched)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldFailAtOnceWithoutAPauseWhenThePackAnswers404() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest))
        XCTAssertEqual(failure, .downloadFailed("HTTP 404 for the pack"))
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.packUrl])
        XCTAssertTrue(harness.clock.sleptSeconds.isEmpty)
    }

    func testShouldDownloadWhenTheManifestFetchDropsTwiceAndTheThirdAttemptArrives() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack)
        harness.http.droppedRequestCounts[release.manifestUrl] = 2
        _ = try await harness.download(release)
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json", "manifest.json", "manifest.json", "pack"])
        XCTAssertEqual(harness.clock.sleptSeconds, [1, 3])
    }

    func testShouldStoreASingleFileWhenItsDownloadDropsTwiceAndTheThirdAttemptArrives() async throws {
        let harness = DownloaderHarness()
        let fileUrl = DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(indexHtml))
        harness.http.stub(fileUrl, body: indexHtml)
        harness.http.droppedRequestCounts[fileUrl] = 2
        _ = try await harness.download(harness.publish(DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count)]), pack: DownloaderHarness.emptyPack))
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.packUrl, fileUrl, fileUrl, fileUrl])
    }

    func testShouldApplyAPatchToAFileOfTheEmbeddedBundle() async throws {
        let harness = DownloaderHarness()
        let old = try BspatchFixture.data("old.bin")
        let new = try BspatchFixture.data("new.bin")
        harness.embedded.files[Hashing.sha256Hex(old)] = old
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.bundle", sha256: Hashing.sha256Hex(new), sizeBytes: new.count)])
        let delta = PackWriter.pack([.patch(fromSha256: Hashing.sha256Hex(old), toSha256: Hashing.sha256Hex(new), body: try BspatchFixture.data("valid.patch"))])
        let outcome = try await harness.download(harness.publish(manifest, deltas: ["b1": delta]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .delta)
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(new))), new)
        XCTAssertFalse(harness.http.requests.contains { $0.url.absoluteString == DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(new)) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path), [])
    }
}
