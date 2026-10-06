import Security
import XCTest
@testable import HotCodePushCore

final class DownloaderTests: XCTestCase {
    private let indexHtml = Data("<html>v2</html>".utf8)
    private let appJs = Data("console.log('v2')".utf8)

    func testShouldRefuseAManifestUrlOffTheConfiguredHosts() async {
        let harness = DownloaderHarness()
        let release = harness.publish(DownloaderHarness.bundle(["index.html": indexHtml]).manifest, manifestUrl: "https://elsewhere.test/manifest.json")
        let failure = await harness.downloadFailure(release)
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertTrue(harness.http.requests.isEmpty)
    }

    func testShouldRefuseAPackUrlOffTheConfiguredHosts() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, packUrl: "https://elsewhere.test/pack"))
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertEqual(harness.http.requests.map { $0.url.host }, ["files.test"])
    }

    func testShouldRefuseAManifestPathThatClimbsOutOfTheServedTree() async {
        let harness = DownloaderHarness()
        let failure = await harness.downloadFailure(harness.publish(DownloaderHarness.bundle(["../../escape.html": indexHtml]).manifest))
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertTrue(harness.files.bundleIds().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("escape.html").path))
    }

    func testShouldRefuseAnEnvelopeNamingAnotherBundle() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, bundleId: "b3"))
        XCTAssertEqual(failure?.reason, .verificationFailed)
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
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldRefuseAPackWhoseLengthDiffersFromTheEnvelope() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, packSizeBytes: bundle.pack.count + 1))
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path), [])
    }

    func testShouldStoreASingleFileThatIsItselfGzipAsItArrives() async throws {
        let harness = DownloaderHarness()
        let archive = try Gzip.compress(Data("console.log('precompressed')".utf8))
        let manifest = DownloaderHarness.manifest(files: [.init(path: "assets/app.js.gz", sha256: Hashing.sha256Hex(archive), sizeBytes: archive.count)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(archive))", body: archive)
        let failure = await harness.downloadFailure(harness.publish(manifest))
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(archive))), archive)
    }

    func testShouldRefuseAPackEntryThatIsNotGzip() async {
        let harness = DownloaderHarness()
        let pack = PackWriter.pack([indexHtml, appJs].map { PackEntry.file(sha256: Hashing.sha256Hex($0), body: $0) })
        let manifest = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs]).manifest
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: pack))
        XCTAssertEqual(failure?.reason, .verificationFailed)
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
        XCTAssertEqual(failure, .invalidSignature("The manifest is unsigned and the app accepts only signed bundles"))
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldRefuseAManifestSignedByAKeyTheAppDoesNotList() async {
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [SigningFixture.publicKey(of: SigningFixture.keyA)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, signingKey: SigningFixture.keyB))
        XCTAssertEqual(failure, .invalidSignature("The manifest is signed by a key the app does not list: \(SigningFixture.keyId(of: SigningFixture.keyB))"))
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldNameTheConfigurationWhenTheSystemCannotImportTheListedKey() async {
        let keyId = SigningFixture.keyId(of: SigningFixture.keyA)
        let harness = DownloaderHarness(configuration: Fixture.configuration(publicKeys: [DevicePublicKey(der: "AQID", keyId: keyId)]))
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack, signingKey: SigningFixture.keyA))
        XCTAssertEqual(failure, .invalidSignature("The app's configuration is wrong: the system cannot import the public key \(keyId) of the resource file as an RSA key"))
        XCTAssertEqual(harness.http.requests.map { $0.url.lastPathComponent }, ["manifest.json"])
    }

    func testShouldApplyAnUnsignedManifestWhenTheAppCarriesNoPublicKey() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack))
        XCTAssertNil(failure)
    }

    func testShouldTakeTheStreamedDeltaWhenTheEnvelopeListsNoDeltaForTheBase() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: bundle.pack)
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), currentBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .streamed)
        XCTAssertEqual(outcome.bytes, bundle.pack.count)
        XCTAssertEqual(harness.http.requests.map { $0.url.host }, ["files.test", "updates.test"])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(appJs)))
    }

    func testShouldTakeTheFullPackWhenTheStreamedDeltaRedirects() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), status: 302, headers: ["Location": DownloaderHarness.packUrl], body: Data())
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), currentBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .full)
        XCTAssertEqual(harness.http.requests.map { $0.url.absoluteString }.suffix(2), [DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), DownloaderHarness.packUrl])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldFetchTheFilesAStreamedDeltaDidNotCarryOneByOne() async throws {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: DownloaderHarness.bundle(["app.js": appJs]).pack)
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let outcome = try await harness.download(harness.publish(bundle.manifest, pack: bundle.pack), currentBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .streamed)
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
        XCTAssertFalse(harness.http.requests.contains { $0.url.absoluteString == DownloaderHarness.packUrl })
    }

    func testShouldRefuseAStreamedDeltaLargerThanTheFullPack() async {
        let harness = DownloaderHarness()
        let bundle = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs])
        harness.http.stub(DownloaderHarness.streamedDeltaUrl(baseBundleId: "b1"), body: bundle.pack + Data(count: 512))
        let failure = await harness.downloadFailure(harness.publish(bundle.manifest, pack: bundle.pack), currentBundleId: "b1")
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldFetchASingleMissingFileWithoutAskingForAStreamedDelta() async throws {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let outcome = try await harness.download(harness.publish(manifest), currentBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .files)
        XCTAssertEqual(harness.http.requests.map { $0.url.host }, ["files.test", "files.test"])
    }

    func testShouldRefuseASingleFileLargerThanItsSize() async {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count - 1)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let failure = await harness.downloadFailure(harness.publish(manifest))
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldApplyAPatchToAFileOfTheEmbeddedBundle() async throws {
        let harness = DownloaderHarness()
        let old = try BspatchFixture.data("old.bin")
        let new = try BspatchFixture.data("new.bin")
        harness.embedded.files[Hashing.sha256Hex(old)] = old
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.bundle", sha256: Hashing.sha256Hex(new), sizeBytes: new.count)])
        let delta = PackWriter.pack([.patch(fromSha256: Hashing.sha256Hex(old), toSha256: Hashing.sha256Hex(new), body: try BspatchFixture.data("valid.patch"))])
        let outcome = try await harness.download(harness.publish(manifest, deltas: ["b1": delta]), currentBundleId: "b1")
        XCTAssertEqual(outcome.packKind, .delta)
        XCTAssertEqual(try Data(contentsOf: harness.files.fileURL(sha256: Hashing.sha256Hex(new))), new)
        XCTAssertFalse(harness.http.requests.contains { $0.url.absoluteString == DownloaderHarness.fileUrl(sha256: Hashing.sha256Hex(new)) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("tmp").path), [])
    }
}

/// A downloader over fakes, in a fresh temporary directory.
final class DownloaderHarness {
    static let bundleId = "b2"
    static let packUrl = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/\(bundleId)/pack"

    static func streamedDeltaUrl(baseBundleId: String) -> String {
        return "\(Fixture.updatesBaseUrl)/v1/apps/\(Fixture.appId)/bundles/\(bundleId)/deltas/\(baseBundleId)"
    }

    static func fileUrl(sha256: String) -> String {
        return "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(sha256)"
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hotcodepush-tests-\(UUID().uuidString)")
    let http = FakeHttpClient()
    let embedded = InMemoryEmbeddedBundle()
    let files: FileStore
    let downloader: Downloader

    init(configuration: Configuration = Fixture.configuration()) {
        files = FileStore(rootDirectory: root.appendingPathComponent("store"))
        downloader = Downloader(configuration: configuration, files: files, embedded: embedded, http: http, temporaryDirectory: root.appendingPathComponent("tmp"))
    }

    /// The manifest of these files and the pack that carries them, each entry the gzip bytes the bucket serves.
    static func bundle(_ files: [String: Data]) -> (manifest: BundleManifest, pack: Data) {
        let sorted = files.sorted { $0.key < $1.key }
        let pack = PackWriter.pack(sorted.map { PackEntry.file(sha256: Hashing.sha256Hex($0.value), body: try! Gzip.compress($0.value)) })
        let entries = sorted.map { BundleManifest.File(path: $0.key, sha256: Hashing.sha256Hex($0.value), sizeBytes: $0.value.count) }
        return (manifest(files: entries), pack)
    }

    static func manifest(files: [BundleManifest.File]) -> BundleManifest {
        return BundleManifest(appId: Fixture.appId, bundleVersion: "1.2.0", files: files, platforms: ["ios"])
    }

    static func replacingFiles(of manifest: BundleManifest, with files: [BundleManifest.File]) -> BundleManifest {
        return BundleManifest(appId: manifest.appId, bundleVersion: manifest.bundleVersion, files: files, fingerprint: manifest.fingerprint, keyId: manifest.keyId, platforms: manifest.platforms)
    }

    /// Serves the envelope, and its pack and delta packs by base bundle when given, where the index entry says they are and
    /// returns that entry; a signing key signs the manifest under its fingerprint.
    func publish(_ manifest: BundleManifest, pack: Data? = nil, packUrl: String = packUrl, packSizeBytes: Int? = nil, deltas: [String: Data] = [:], bundleId: String = bundleId, manifestUrl: String = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/\(bundleId)/manifest.json", signingKey: SecKey? = nil) -> IndexRelease {
        let signed = signingKey.map { key in BundleManifest(appId: manifest.appId, bundleVersion: manifest.bundleVersion, files: manifest.files, fingerprint: manifest.fingerprint, keyId: SigningFixture.keyId(of: key), platforms: manifest.platforms) } ?? manifest
        let json = String(bytes: try! Json.encoder.encode(signed), encoding: .utf8) ?? ""
        var envelopeDeltas: [ManifestEnvelope.Delta] = []
        for (baseBundleId, delta) in deltas {
            let url = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/\(bundleId)/deltas/\(baseBundleId)"
            http.stub(url, body: delta)
            envelopeDeltas.append(.init(baseBundleId: baseBundleId, url: url, sizeBytes: delta.count))
        }
        http.stubJson(manifestUrl, ManifestEnvelope(bundleId: bundleId, createdAt: Fixture.builtAt, manifest: json, signature: signingKey.map { SigningFixture.sign(json, with: $0) }, pack: .init(url: packUrl, sizeBytes: packSizeBytes ?? pack?.count ?? 0), deltas: envelopeDeltas))
        if let pack = pack {
            http.stub(packUrl, body: pack)
        }
        return IndexRelease(id: "r2", number: 2, createdAt: Fixture.builtAt, bundleId: DownloaderHarness.bundleId, bundleVersion: manifest.bundleVersion, manifestUrl: manifestUrl, manifestSha256: Hashing.sha256Hex(json), sizeBytes: 0)
    }

    func download(_ release: IndexRelease, currentBundleId: String? = nil) async throws -> DownloadOutcome {
        return try await downloader.downloadRelease(release, currentBundleId: currentBundleId) { _, _ in }
    }

    func downloadFailure(_ release: IndexRelease, currentBundleId: String? = nil) async -> DownloadFailure? {
        do {
            _ = try await download(release, currentBundleId: currentBundleId)
            return nil
        } catch {
            return error as? DownloadFailure
        }
    }
}
