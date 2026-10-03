import Foundation
@testable import HotCodePushProtocol

final class FakeHttpClient: HttpClient {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    var stubs: [String: Stub] = [:]
    var requests: [(url: URL, headers: [String: String])] = []
    var posts: [(url: URL, headers: [String: String], body: Data)] = []
    var isOffline = false

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        stubs[url] = Stub(status: status, headers: headers, body: body)
    }

    func stubJson<T: Encodable>(_ url: String, _ value: T, status: Int = 200, headers: [String: String] = [:]) {
        stub(url, status: status, headers: headers, body: try! Json.encoder.encode(value))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse {
        requests.append((url, headers))
        if isOffline { throw URLError(.notConnectedToInternet) }
        guard let stub = stubs[url.absoluteString] else { return HttpResponse(status: 404, headers: [:], body: Data()) }
        return HttpResponse(status: stub.status, headers: stub.headers, body: stub.body)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse {
        posts.append((url, headers, body))
        if isOffline { throw URLError(.notConnectedToInternet) }
        guard let stub = stubs[url.absoluteString] else { return HttpResponse(status: 404, headers: [:], body: Data()) }
        return HttpResponse(status: stub.status, headers: stub.headers, body: stub.body)
    }

    func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws {
        requests.append((url, [:]))
        if isOffline { throw URLError(.notConnectedToInternet) }
        guard let stub = stubs[url.absoluteString], stub.status == 200 else { throw DownloadFailure.downloadFailed("HTTP 404") }
        guard stub.body.count <= maximumBytes else { throw DownloadFailure.downloadFailed("\(url.lastPathComponent) is larger than its \(maximumBytes) bytes") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stub.body.write(to: file)
        progress(stub.body.count, stub.body.count)
    }
}

final class InMemoryStore: KeyValueStore {
    private(set) var values: [String: String] = [:]
    private(set) var integers: [String: Int] = [:]

    init() {}

    func string(forKey key: String) -> String? {
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        values[key] = value
    }

    func integer(forKey key: String) -> Int? {
        return integers[key]
    }

    func set(_ value: Int?, forKey key: String) {
        integers[key] = value
    }
}

final class FakeLoader: BundleLoader {
    let root: URL
    var persisted: String??
    var loaded: [String?] = []
    var served: String?
    var isMetered = false

    init(root: URL) {
        self.root = root
    }

    func projectionDirectory(bundleId: String) -> URL {
        return root.appendingPathComponent("www").appendingPathComponent(bundleId)
    }

    func deleteProjection(bundleId: String) {
        try? FileManager.default.removeItem(at: projectionDirectory(bundleId: bundleId))
    }

    func persistServedBundle(bundleId: String?) {
        persisted = .some(bundleId)
    }

    func loadServedBundle(bundleId: String?) {
        loaded.append(bundleId)
        served = bundleId
    }

    func servedBundleId() -> String? {
        return served
    }

    func isConnectionMetered() -> Bool {
        return isMetered
    }
}

final class FakeListener: CoreListener {
    var available: [UpdateAvailableEvent] = []
    var downloaded: [UpdateDownloadedEvent] = []
    var failed: [UpdateFailedEvent] = []
    var progress: [(String, Int, Int)] = []
    var rolledBack: [RolledBackEvent] = []

    func updateAvailable(_ event: UpdateAvailableEvent) { available.append(event) }
    func updateDownloaded(_ event: UpdateDownloadedEvent) { downloaded.append(event) }
    func updateFailed(_ event: UpdateFailedEvent) { failed.append(event) }
    func downloadProgress(releaseId: String, downloadedBytes: Int, totalBytes: Int) { progress.append((releaseId, downloadedBytes, totalBytes)) }
    func rolledBack(_ event: RolledBackEvent) { rolledBack.append(event) }
}

final class ManualScheduler: Scheduler {
    final class Task: ScheduledTask {
        let seconds: TimeInterval
        let block: () -> Void
        var isCancelled = false
        init(seconds: TimeInterval, block: @escaping () -> Void) { self.seconds = seconds; self.block = block }
        func cancel() { isCancelled = true }
    }

    var tasks: [Task] = []

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> ScheduledTask {
        let task = Task(seconds: seconds, block: block)
        tasks.append(task)
        return task
    }

    /// Fires every pending task that is still alive, the way time would.
    func fire() {
        let pending = tasks
        tasks = []
        for task in pending where !task.isCancelled {
            task.block()
        }
    }
}

final class FixedClock: Clock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

final class InMemoryEmbeddedBundle: EmbeddedBundle {
    var files: [String: Data] = [:]

    func has(sha256: String) -> Bool {
        return files[sha256] != nil
    }

    func copyFile(sha256: String, to destination: URL) throws {
        try files[sha256]!.write(to: destination)
    }
}

/// One app, one channel, the fixtures every test starts from.
struct Fixture {
    static let appId = "a0000000-0000-4000-8000-000000000001"
    static let channelId = "c0000000-0000-4000-8000-000000000001"
    static let filesBaseUrl = "https://files.test"
    static let updatesBaseUrl = "https://updates.test"
    static let builtAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let embeddedIndexHtml = Data("<html>v1</html>".utf8)

    static func embeddedManifest() -> BundleManifest {
        return BundleManifest(bundleId: "embedded", appId: appId, version: "1.0.0", createdAt: builtAt, files: [.init(path: "index.html", sha256: Hashing.sha256Hex(embeddedIndexHtml), sizeBytes: embeddedIndexHtml.count)])
    }

    static func configuration(installStrategy: InstallStrategy = .nextStart, mandatoryInstallStrategy: MandatoryInstallStrategy = .immediate, downloadStrategy: DownloadStrategy = .auto, autoCheck: Bool = false, readySignal: ReadySignal = .render, publicKeys: [String] = [], fingerprint: String? = "fp1:abc", builtAt: Date = Fixture.builtAt, enabledInDebugBuilds: Bool = true) -> Configuration {
        let json: [String: Any] = [
            "appId": appId,
            "channelId": channelId,
            "autoCheck": autoCheck,
            "checkInterval": 900,
            "downloadStrategy": downloadStrategy.rawValue,
            "installStrategy": installStrategy.rawValue,
            "mandatoryInstallStrategy": mandatoryInstallStrategy.rawValue,
            "installOnResumeAfter": 300,
            "readySignal": readySignal.rawValue,
            "readyTimeout": 10,
            "enabledInDebugBuilds": enabledInDebugBuilds,
            "publicKeys": publicKeys,
            "builtAt": Iso8601.format(builtAt),
            "fingerprint": fingerprint as Any,
            "embeddedBundleManifest": try! JSONSerialization.jsonObject(with: try! Json.encoder.encode(embeddedManifest())),
            "embeddedBundleId": "embedded",
            "filesBaseUrl": filesBaseUrl,
            "updatesBaseUrl": updatesBaseUrl
        ]
        return try! Configuration.decode(try! JSONSerialization.data(withJSONObject: json))
    }

    static func indexUrl() -> String {
        return "\(filesBaseUrl)/apps/\(appId)/channels/\(channelId)/ios/v1/index.json"
    }

    static func eventsUrl() -> String {
        return "\(updatesBaseUrl)/v1/apps/\(appId)/events"
    }

    static func release(number: Int, bundleId: String, content: Data, createdAt: Date = builtAt.addingTimeInterval(60), rollout: Int = 100, conditions: [Condition] = [], isMandatory: Bool = false) -> (release: IndexRelease, manifest: BundleManifest, envelope: ManifestEnvelope, pack: Data) {
        let sha256 = Hashing.sha256Hex(content)
        let js = Data("js-\(bundleId)".utf8)
        let pack = PackWriter.pack([
            PackEntry(sha256: sha256, body: try! Gzip.compress(content)),
            PackEntry(sha256: Hashing.sha256Hex(js), body: try! Gzip.compress(js))
        ])
        let manifest = BundleManifest(bundleId: bundleId, appId: appId, version: "1.\(number).0", createdAt: createdAt, files: [.init(path: "index.html", sha256: sha256, sizeBytes: content.count), .init(path: "assets/app.js", sha256: Hashing.sha256Hex(js), sizeBytes: js.count)], pack: .init(url: "\(filesBaseUrl)/apps/\(appId)/bundles/\(bundleId)/pack", sizeBytes: pack.count))
        let manifestJson = String(bytes: try! Json.encoder.encode(manifest), encoding: .utf8) ?? ""
        let envelope = ManifestEnvelope(manifest: manifestJson, signature: nil)
        let release = IndexRelease(id: "r\(number)", number: number, createdAt: createdAt, isMandatory: isMandatory, notes: "notes \(number)", rollout: rollout, conditions: conditions, bundleId: bundleId, bundleVersion: manifest.version, manifestUrl: "\(filesBaseUrl)/apps/\(appId)/bundles/\(bundleId)/manifest.json", manifestSha256: Hashing.sha256Hex(manifestJson), sizeBytes: content.count)
        return (release, manifest, envelope, pack)
    }

    static func index(sequence: Int, releases: [IndexRelease], revoked: [String] = [], isPaused: Bool = false, cappedAt: Date? = nil, rollBackToEmbedded: RollBackToEmbedded? = nil) -> ChannelIndex {
        return ChannelIndex(sequence: sequence, appId: appId, channelId: channelId, platform: "ios", isPaused: isPaused, cappedAt: cappedAt, revokedReleaseIds: revoked, rollBackToEmbedded: rollBackToEmbedded, releases: releases)
    }
}

/// A core over fakes, in a fresh temporary directory.
final class Harness {
    let root: URL
    let store = InMemoryStore()
    let http = FakeHttpClient()
    let loader: FakeLoader
    let listener = FakeListener()
    let scheduler = ManualScheduler()
    let embedded = InMemoryEmbeddedBundle()
    let clock = FixedClock(now: Fixture.builtAt.addingTimeInterval(3600))
    let files: FileStore
    private let device: DeviceFacts
    var core: Core

    init(configuration: Configuration = Fixture.configuration(), isDebugBuild: Bool = false) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hotcodepush-tests-\(UUID().uuidString)")
        loader = FakeLoader(root: root)
        files = FileStore(rootDirectory: root.appendingPathComponent("store"))
        device = DeviceFacts(platform: "ios", binaryVersion: "2.4.1", binaryBuild: "57", osVersion: "17.4", sdkVersion: "0.0.0", isDebugBuild: isDebugBuild)
        embedded.files[Hashing.sha256Hex(Fixture.embeddedIndexHtml)] = Fixture.embeddedIndexHtml
        core = Core(configuration: configuration, device: device, store: store, files: files, embedded: embedded, http: http, loader: loader, listener: listener, scheduler: scheduler, clock: clock, temporaryDirectory: root.appendingPathComponent("tmp"))
    }

    /// A second core over the same store and files: the next start of the app.
    func restart(configuration: Configuration = Fixture.configuration()) {
        core = Core(configuration: configuration, device: device, store: store, files: files, embedded: embedded, http: http, loader: loader, listener: listener, scheduler: scheduler, clock: clock, temporaryDirectory: root.appendingPathComponent("tmp"))
    }

    /// The events endpoint answering every batch with the same server time.
    func acknowledgeEvents(reportedAt: String = "2023-11-14T23:00:00.000Z") {
        http.stubJson(Fixture.eventsUrl(), ["reportedAt": reportedAt], status: 202)
    }

    func publish(_ releases: [(release: IndexRelease, manifest: BundleManifest, envelope: ManifestEnvelope, pack: Data)], sequence: Int, revoked: [String] = [], isPaused: Bool = false, cappedAt: Date? = nil, rollBackToEmbedded: RollBackToEmbedded? = nil, etag: String = "\"e1\"") {
        http.stubJson(Fixture.indexUrl(), Fixture.index(sequence: sequence, releases: releases.map { $0.release }, revoked: revoked, isPaused: isPaused, cappedAt: cappedAt, rollBackToEmbedded: rollBackToEmbedded), headers: ["ETag": etag])
        for entry in releases {
            http.stubJson(entry.release.manifestUrl, entry.envelope)
            http.stub(entry.manifest.pack!.url, body: entry.pack)
        }
    }
}
