import XCTest
@testable import HotCodePushProtocol

final class StoreTests: XCTestCase {
    func testShouldKeepTheIdentityKeysAndDropTheCacheOnAnUnknownStateVersion() {
        let store = InMemoryStore()
        store.set(9, forKey: "hotcodepush.stateVersion")
        store.set("{\"id\":\"r1\",\"number\":1,\"bundleId\":\"b1\",\"bundleVersion\":\"1\",\"isMandatory\":false}", forKey: "hotcodepush.currentRelease")
        store.set("device-1", forKey: "hotcodepush.deviceId")
        let state = StateStore(store: store)
        XCTAssertEqual(state.deviceId, "device-1")
        XCTAssertNil(state.currentRelease)
        XCTAssertEqual(store.integer(forKey: "hotcodepush.stateVersion"), 2)
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
        state.nextRelease = Release(id: "r1", number: 1, bundleId: "b1", bundleVersion: "1", isMandatory: false)
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
        XCTAssertEqual(files.bundleIds(), ["kept"])
        XCTAssertTrue(files.hasFile(sha256: Hashing.sha256Hex("a")))
        XCTAssertFalse(files.hasFile(sha256: Hashing.sha256Hex("b")))
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
