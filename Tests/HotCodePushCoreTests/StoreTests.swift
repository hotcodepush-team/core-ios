import XCTest
@testable import HotCodePushCore

final class StoreTests: XCTestCase {
    func testShouldKeepTheIdentityKeysAndDropTheCacheOnAnUnknownStateVersion() {
        let store = InMemoryStore()
        store.set(9, forKey: "hotcodepush.stateVersion")
        store.set("{\"id\":\"r1\",\"number\":1,\"bundleId\":\"b1\",\"bundleVersion\":\"1\",\"isMandatory\":false}", forKey: "hotcodepush.currentRelease")
        store.set("device-1", forKey: "hotcodepush.deviceId")
        let state = StateStore(store: store)
        XCTAssertEqual(state.deviceId, "device-1")
        XCTAssertNil(state.currentRelease)
        XCTAssertEqual(store.integer(forKey: "hotcodepush.stateVersion"), StateStore.stateVersion)
    }

    func testShouldDropAnOldReasonWhenThePreviousStateVersionStoredIt() {
        let store = InMemoryStore()
        let release = "{\"id\":\"r1\",\"number\":1,\"bundleId\":\"b1\",\"bundleVersion\":\"1\",\"isMandatory\":false}"
        store.set(2, forKey: "hotcodepush.stateVersion")
        store.set("{\"from\":\(release),\"to\":null,\"reason\":\"CRASHED\"}", forKey: "hotcodepush.pendingRollbackEvent")
        store.set("[{\"type\":\"failed\",\"releaseId\":\"r1\",\"reason\":\"CRASHED\"}]", forKey: "hotcodepush.unsentEvents")
        store.set("device-1", forKey: "hotcodepush.deviceId")
        let state = StateStore(store: store)
        XCTAssertNil(state.pendingRollbackEvent)
        XCTAssertEqual(state.unsentEvents, [])
        XCTAssertEqual(state.deviceId, "device-1")
    }

    func testShouldDropANextReleaseStoredWithoutItsApplyMomentByTheThirdStateVersion() {
        let store = InMemoryStore()
        let release = "{\"id\":\"r1\",\"number\":1,\"bundleId\":\"b1\",\"bundleVersion\":\"1\",\"isMandatory\":false}"
        store.set(3, forKey: "hotcodepush.stateVersion")
        store.set(release, forKey: "hotcodepush.nextRelease")
        store.set(release, forKey: "hotcodepush.currentRelease")
        store.set("device-1", forKey: "hotcodepush.deviceId")
        let state = StateStore(store: store)
        XCTAssertNil(state.nextRelease)
        XCTAssertNil(state.currentRelease)
        XCTAssertEqual(state.deviceId, "device-1")
    }

    func testShouldDropAnOutboxStoredInTheOldSpellingByTheFourthStateVersion() {
        let store = InMemoryStore()
        store.set(4, forKey: "hotcodepush.stateVersion")
        store.set("[{\"type\":\"checked\",\"releaseId\":\"r1\",\"status\":\"AVAILABLE\"},{\"type\":\"rolledBack\",\"fromReleaseId\":\"r1\",\"toReleaseId\":null}]", forKey: "hotcodepush.unsentEvents")
        store.set("device-1", forKey: "hotcodepush.deviceId")
        let state = StateStore(store: store)
        XCTAssertEqual(state.unsentEvents, [])
        XCTAssertEqual(state.deviceId, "device-1")
    }

    func testShouldStoreTheNextReleaseWithItsApplyMoment() throws {
        let store = InMemoryStore()
        let next = NextRelease(release: Release(id: "r1", number: 1, bundleId: "b1", bundleVersion: "1", isMandatory: false), applyStrategy: .nextResume)
        StateStore(store: store).nextRelease = next
        XCTAssertEqual(StateStore(store: store).nextRelease, next)
        let stored = try XCTUnwrap(store.string(forKey: "hotcodepush.nextRelease"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["release", "applyStrategy"])
        XCTAssertEqual(object["applyStrategy"] as? String, "next_resume")
    }

    func testShouldGenerateAStableDeviceIdOnce() {
        let store = InMemoryStore()
        let state = StateStore(store: store)
        let id = state.deviceId
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(StateStore(store: store).deviceId, id)
    }

    func testShouldDropTheCacheWhenAValueDoesNotParse() {
        let store = InMemoryStore()
        let state = StateStore(store: store)
        state.nextRelease = NextRelease(release: Release(id: "r1", number: 1, bundleId: "b1", bundleVersion: "1", isMandatory: false), applyStrategy: .nextStart)
        store.set("not json", forKey: "hotcodepush.currentRelease")
        XCTAssertNil(state.currentRelease)
        XCTAssertNil(state.nextRelease)
    }

    func testShouldStoreTheChannelChoiceInBothShapes() {
        let state = StateStore(store: InMemoryStore())
        state.channel = .name("staging")
        XCTAssertEqual(state.channel, .name("staging"))
        state.channel = .id("c1")
        XCTAssertEqual(state.channel, .id("c1"))
        state.channel = nil
        XCTAssertNil(state.channel)
    }
}

final class FileStoreTests: XCTestCase {
    func testShouldRefuseAFileWhoseHashDoesNotMatch() throws {
        let files = FileStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try files.writeFile(Data("a".utf8), sha256: "0"))
        try files.writeFile(Data("a".utf8), sha256: Hashing.sha256Hex("a"))
        XCTAssertTrue(files.hasFile(sha256: Hashing.sha256Hex("a")))
    }

    func testShouldCollectWhatNoKeptBundleLists() throws {
        let files = FileStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let kept = BundleManifest(appId: "a", bundleVersion: "1", files: [.init(path: "a", sha256: Hashing.sha256Hex("a"), sizeBytes: 1)], platforms: ["ios"])
        let gone = BundleManifest(appId: "a", bundleVersion: "1", files: [.init(path: "b", sha256: Hashing.sha256Hex("b"), sizeBytes: 1)], platforms: ["ios"])
        try files.writeManifest(kept, bundleId: "kept")
        try files.writeManifest(gone, bundleId: "gone")
        try files.writeFile(Data("a".utf8), sha256: Hashing.sha256Hex("a"))
        try files.writeFile(Data("b".utf8), sha256: Hashing.sha256Hex("b"))
        files.deleteUnusedFiles(keepingBundleIds: ["kept"])
        XCTAssertTrue(files.hasFile(sha256: Hashing.sha256Hex("a")))
        XCTAssertFalse(files.hasFile(sha256: Hashing.sha256Hex("b")))
    }

    func testShouldKeepTheDefaultStoreInApplicationSupport() throws {
        let applicationSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(FileStore.defaultRootDirectory, applicationSupport.appendingPathComponent("hotcodepush", isDirectory: true))
    }

    func testShouldKeepTheStoreOutOfDeviceBackups() throws {
        let files = FileStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try files.writeFile(Data("a".utf8), sha256: Hashing.sha256Hex("a"))
        XCTAssertEqual(try files.rootDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testShouldKeepAServedTreeOutOfDeviceBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileStore(rootDirectory: root.appendingPathComponent("store"))
        try files.writeFile(Data("new".utf8), sha256: Hashing.sha256Hex("new"))
        let manifest = BundleManifest(appId: "a", bundleVersion: "1", files: [.init(path: "index.html", sha256: Hashing.sha256Hex("new"), sizeBytes: 3)], platforms: ["ios"])
        let www = root.appendingPathComponent("www")
        try BundleProjection.project(manifest, from: files, embedded: InMemoryEmbeddedBundle(), into: www)
        XCTAssertEqual(try www.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testShouldProjectABundleByPathFromTheStoreAndTheEmbeddedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileStore(rootDirectory: root.appendingPathComponent("store"))
        let embedded = InMemoryEmbeddedBundle()
        embedded.files[Hashing.sha256Hex("embedded")] = Data("embedded".utf8)
        try files.writeFile(Data("new".utf8), sha256: Hashing.sha256Hex("new"))
        let manifest = BundleManifest(appId: "a", bundleVersion: "1", files: [.init(path: "index.html", sha256: Hashing.sha256Hex("new"), sizeBytes: 3), .init(path: "assets/logo.svg", sha256: Hashing.sha256Hex("embedded"), sizeBytes: 8)], platforms: ["ios"])
        let www = root.appendingPathComponent("www")
        try BundleProjection.project(manifest, from: files, embedded: embedded, into: www)
        XCTAssertEqual(try Data(contentsOf: www.appendingPathComponent("index.html")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: www.appendingPathComponent("assets/logo.svg")), Data("embedded".utf8))
    }
}

final class UserDefaultsStoreTests: XCTestCase {
    func testShouldRemoveTheKeyWhenANilStringOrIntegerIsSet() throws {
        let suiteName = "hotcodepush.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsStore(defaults: defaults)
        store.set("value", forKey: "string")
        store.set(1, forKey: "integer")
        XCTAssertEqual(store.string(forKey: "string"), "value")
        XCTAssertEqual(store.integer(forKey: "integer"), 1)
        store.set(nil as String?, forKey: "string")
        store.set(nil as Int?, forKey: "integer")
        XCTAssertNil(defaults.object(forKey: "string"))
        XCTAssertNil(defaults.object(forKey: "integer"))
    }
}

final class AppBundleEmbeddedBundleTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func testShouldCopyAListedFileFromUnderTheRootDirectory() throws {
        try writeFile("public/assets/logo.svg", content: "logo")
        let embedded = AppBundleEmbeddedBundle(manifest: manifest(path: "assets/logo.svg", content: "logo"), rootDirectory: root.appendingPathComponent("public"))
        let destination = root.appendingPathComponent("copy.svg")
        XCTAssertTrue(embedded.has(sha256: Hashing.sha256Hex("logo")))
        try embedded.copyFile(sha256: Hashing.sha256Hex("logo"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("logo".utf8))
    }

    func testShouldHaveNoFileWhenTheBinaryLacksIt() {
        let embedded = AppBundleEmbeddedBundle(manifest: manifest(path: "assets/logo.svg", content: "logo"), rootDirectory: root)
        XCTAssertFalse(embedded.has(sha256: Hashing.sha256Hex("logo")))
    }

    func testShouldHaveNoFileTheManifestDoesNotList() throws {
        try writeFile("index.html", content: "index")
        let embedded = AppBundleEmbeddedBundle(manifest: manifest(path: "assets/logo.svg", content: "logo"), rootDirectory: root)
        XCTAssertFalse(embedded.has(sha256: Hashing.sha256Hex("index")))
        XCTAssertThrowsError(try embedded.copyFile(sha256: Hashing.sha256Hex("index"), to: root.appendingPathComponent("copy.html")))
    }

    func testShouldHaveNoFileWhenTheBuildCarriesNoManifest() throws {
        try writeFile("index.html", content: "index")
        XCTAssertFalse(AppBundleEmbeddedBundle(manifest: nil, rootDirectory: root).has(sha256: Hashing.sha256Hex("index")))
    }

    private func manifest(path: String, content: String) -> EmbeddedBundleManifest {
        return BundleManifest(appId: "a", bundleVersion: "1", files: [.init(path: path, sha256: Hashing.sha256Hex(content), sizeBytes: content.utf8.count)], platforms: ["ios"])
    }

    private func writeFile(_ path: String, content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}
