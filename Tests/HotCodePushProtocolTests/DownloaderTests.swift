import XCTest
@testable import HotCodePushProtocol

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
        let pack = PackWriter.pack([indexHtml, appJs].map { PackEntry(sha256: Hashing.sha256Hex($0), body: $0) })
        let manifest = DownloaderHarness.bundle(["index.html": indexHtml, "app.js": appJs]).manifest
        let failure = await harness.downloadFailure(harness.publish(manifest, pack: pack))
        XCTAssertEqual(failure?.reason, .verificationFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }

    func testShouldRefuseASingleFileLargerThanItsSize() async {
        let harness = DownloaderHarness()
        let manifest = DownloaderHarness.manifest(files: [.init(path: "index.html", sha256: Hashing.sha256Hex(indexHtml), sizeBytes: indexHtml.count - 1)])
        harness.http.stub("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/files/\(Hashing.sha256Hex(indexHtml))", body: indexHtml)
        let failure = await harness.downloadFailure(harness.publish(manifest))
        XCTAssertEqual(failure?.reason, .downloadFailed)
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex(indexHtml)))
    }
}

/// A downloader over fakes, in a fresh temporary directory.
final class DownloaderHarness {
    static let bundleId = "b2"
    static let packUrl = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/\(bundleId)/pack"

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hotcodepush-tests-\(UUID().uuidString)")
    let http = FakeHttpClient()
    let files: FileStore
    let downloader: Downloader

    init() {
        files = FileStore(rootDirectory: root.appendingPathComponent("store"))
        downloader = Downloader(configuration: Fixture.configuration(), files: files, embedded: InMemoryEmbeddedBundle(), http: http, temporaryDirectory: root.appendingPathComponent("tmp"))
    }

    /// The manifest of these files and the pack that carries them, each entry the gzip bytes the bucket serves.
    static func bundle(_ files: [String: Data]) -> (manifest: BundleManifest, pack: Data) {
        let sorted = files.sorted { $0.key < $1.key }
        let pack = PackWriter.pack(sorted.map { PackEntry(sha256: Hashing.sha256Hex($0.value), body: try! Gzip.compress($0.value)) })
        let entries = sorted.map { BundleManifest.File(path: $0.key, sha256: Hashing.sha256Hex($0.value), sizeBytes: $0.value.count) }
        return (manifest(files: entries), pack)
    }

    static func manifest(files: [BundleManifest.File]) -> BundleManifest {
        return BundleManifest(appId: Fixture.appId, bundleVersion: "1.2.0", files: files, platforms: ["ios"])
    }

    static func replacingFiles(of manifest: BundleManifest, with files: [BundleManifest.File]) -> BundleManifest {
        return BundleManifest(appId: manifest.appId, bundleVersion: manifest.bundleVersion, files: files, fingerprint: manifest.fingerprint, keyId: manifest.keyId, patches: manifest.patches, platforms: manifest.platforms)
    }

    /// Serves the envelope, and its pack when given, where the index entry says they are and returns that entry.
    func publish(_ manifest: BundleManifest, pack: Data? = nil, packUrl: String = packUrl, packSizeBytes: Int? = nil, bundleId: String = bundleId, manifestUrl: String = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/\(bundleId)/manifest.json") -> IndexRelease {
        let json = String(bytes: try! Json.encoder.encode(manifest), encoding: .utf8) ?? ""
        http.stubJson(manifestUrl, ManifestEnvelope(bundleId: bundleId, createdAt: Fixture.builtAt, manifest: json, pack: .init(url: packUrl, sizeBytes: packSizeBytes ?? pack?.count ?? 0)))
        if let pack = pack {
            http.stub(packUrl, body: pack)
        }
        return IndexRelease(id: "r2", number: 2, createdAt: Fixture.builtAt, bundleId: DownloaderHarness.bundleId, bundleVersion: manifest.bundleVersion, manifestUrl: manifestUrl, manifestSha256: Hashing.sha256Hex(json), sizeBytes: 0)
    }

    func downloadFailure(_ release: IndexRelease) async -> DownloadFailure? {
        do {
            _ = try await downloader.downloadRelease(release, currentBundleId: nil) { _, _ in }
            return nil
        } catch {
            return error as? DownloadFailure
        }
    }
}
