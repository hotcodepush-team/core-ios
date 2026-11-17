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

    func testShouldFailADownloadWhoseFullPackDoesNotFitInTheFreeSpaceWhenASmallerDeltaComesFirst() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, packSizeBytes: Int.max / 4, deltas: ["b1": bundle.pack])
        let failure = await harness.downloadFailure(release, baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [])
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

    func testShouldFailWithContentMismatchedWhenTheFullPackLacksAListedFile() async {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs]).manifest
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: DownloaderHarness.bundle(["app.js": appJs]).pack))
        XCTAssertEqual(failure, .contentMismatched("The pack lacks the file index.html"))
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

    func testShouldTakeTheFullPackBeforeTheDeltaRouteAnswersAndAskTheRouteOnceAlsoWhenItGetsNoAnswer() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let deltaRouteUrl = DownloaderHarness.deltaRouteUrl(baseBundleId: "b1")
        harness.http.droppedRequestCounts[deltaRouteUrl] = 1
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.packUrl])
        await harness.backgroundWork.runAll()
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.packUrl, deltaRouteUrl])
    }

    func testShouldRefuseAManifestWhoseFullPackOrListedDeltaUrlIsOffTheConfiguredHostsBeforeTheDeltaIsRequested() async throws {
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let offHostPack = DownloaderHarness()
        let offHostPackRelease = offHostPack.publish(bundle.manifest, pack: bundle.pack, packUrl: "https://elsewhere.test/pack", deltas: ["b1": bundle.pack])
        let offHostPackFailure = await offHostPack.downloadFailure(offHostPackRelease, baseBundleId: "b1")
        XCTAssertEqual(offHostPackFailure?.reason, .manifestInvalid)
        XCTAssertEqual(offHostPack.requestUrlsAfterManifest(), [])
        let offHostDelta = DownloaderHarness()
        let offHostDeltaRelease = offHostDelta.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        let envelope = try Json.decoder.decode(ManifestEnvelope.self, from: try XCTUnwrap(offHostDelta.http.stubs[offHostDeltaRelease.manifestUrl]).body)
        let offHostListedDelta = ManifestEnvelope.Delta(baseBundleId: "b0", url: "https://elsewhere.test/delta", sizeBytes: bundle.pack.count)
        offHostDelta.http.stubJson(offHostDeltaRelease.manifestUrl, ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: envelope.manifest, pack: envelope.pack, deltas: envelope.deltas + [offHostListedDelta]))
        let offHostDeltaFailure = await offHostDelta.downloadFailure(offHostDeltaRelease, baseBundleId: "b1")
        XCTAssertEqual(offHostDeltaFailure?.reason, .manifestInvalid)
        XCTAssertEqual(offHostDelta.requestUrlsAfterManifest(), [])
    }

    func testShouldTakeTheFullPackWhenTheDeltaTheEnvelopeListsIsRefused() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        harness.http.stub(DownloaderHarness.deltaUrl(baseBundleId: "b1"), status: 404, body: Data())
        let outcome = try await harness.download(release, baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldTakeTheFullPackWhenAnEntryOfTheDeltaDoesNotVerify() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let delta = PackWriter.pack([.file(sha256: Hashing.sha256Hex(appJs), body: try Gzip.compress(appJs)), .file(sha256: Hashing.sha256Hex(indexHtml), body: try Gzip.compress(Data("<html>v3</html>".utf8)))])
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": delta]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldTakeTheFullPackWhenNoAttemptOfTheDeltaGetsAnAnswer() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        harness.http.droppedRequestCounts[DownloaderHarness.deltaUrl(baseBundleId: "b1")] = 3
        let outcome = try await harness.download(release, baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), Array(repeating: DownloaderHarness.deltaUrl(baseBundleId: "b1"), count: 3) + [DownloaderHarness.packUrl])
    }

    func testShouldFailTheDownloadWithoutTheFullPackWhenTheDevicesStorageFails() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        try FileManager.default.createDirectory(at: harness.files.rootDirectory, withIntermediateDirectories: true)
        try Data().write(to: harness.files.filesDirectory)
        let failure = await harness.downloadFailure(release, baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1")])
    }

    func testShouldTakeTheFullPackAndCountItsBytesAloneWhenAFileIsStillMissingAfterADelta() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let delta = DownloaderHarness.bundle(["app.js": appJs]).pack
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": delta]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(outcome.downloadSizeBytes, bundle.pack.count)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldFailWithTheFullPacksReasonWhenTheFullPackAfterADeltaThatLeftAFileMissingGetsNoAnswer() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": DownloaderHarness.bundle(["app.js": appJs]).pack])
        harness.http.droppedRequestCounts[DownloaderHarness.packUrl] = 3
        let failure = await harness.downloadFailure(release, baseBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
    }

    func testShouldTakeTheFullPackWhenThePatchCodeOfTheDeltaFailsToReadItsBase() async throws {
        let harness = DownloaderHarness()
        let old = try BspatchFixture.data("old.bin")
        let new = try BspatchFixture.data("new.bin")
        try FileManager.default.createDirectory(at: harness.files.fileURL(sha256: Hashing.sha256Hex(old)), withIntermediateDirectories: true)
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.bundle", sha256: Hashing.sha256Hex(new), sizeBytes: new.count)])
        let delta = PackWriter.pack([.patch(fromSha256: Hashing.sha256Hex(old), toSha256: Hashing.sha256Hex(new), body: try BspatchFixture.data("valid.patch"))])
        let fullPack = PackWriter.pack([.file(sha256: Hashing.sha256Hex(new), body: try Gzip.compress(new))])
        let outcome = try await harness.download(harness.publish(manifest, pack: fullPack, deltas: ["b1": delta]), baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(new))), new)
    }

    func testShouldRemoveThePartialFileOfTheDeltaWhenTheDownloadMovesOnToTheFullPack() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        let deltaFile = harness.downloader.resolvePackFile(PackSource(url: DownloaderHarness.deltaUrl(baseBundleId: "b1"), sizeBytes: bundle.pack.count, kind: .delta), bundleId: DownloaderHarness.bundleId)
        try FileManager.default.createDirectory(at: deltaFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier part".utf8).write(to: deltaFile)
        harness.http.droppedRequestCounts[DownloaderHarness.deltaUrl(baseBundleId: "b1")] = 3
        let outcome = try await harness.download(release, baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deltaFile.path))
    }

    func testShouldTakeTheFullPackWhenTheDeltaFailsWithATransportErrorThatIsNotAUrlError() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let release = harness.publish(bundle.manifest, pack: bundle.pack, deltas: ["b1": bundle.pack])
        harness.http.transportErrors[DownloaderHarness.deltaUrl(baseBundleId: "b1")] = POSIXError(.ECONNRESET)
        let outcome = try await harness.download(release, baseBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.requestUrlsAfterManifest(), [DownloaderHarness.deltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
    }

    func testShouldNotBlameTheFullPackForAFileThatVanishesFromTheDeviceWhileThePackArrives() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        try harness.files.writeFile(appJs, sha256: Hashing.sha256Hex(appJs))
        harness.http.whileDownloading = { [files = harness.files, appJs] in
            try? FileManager.default.removeItem(at: files.fileURL(sha256: Hashing.sha256Hex(appJs)))
        }
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertEqual(outcome.packKind, .full)
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path), [])
    }
}
