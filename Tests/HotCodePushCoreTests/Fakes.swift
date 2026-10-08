import Foundation
@testable import HotCodePushCore

/// A value the test and the core's tasks reach from different threads: every read, write and mutation under one lock.
@propertyWrapper
final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    var projectedValue: Locked<Value> { self }

    /// A read and a write as one step, so two appends from two threads both land.
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

final class FakeHttpClient: HttpClient {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    @Locked var stubs: [String: Stub] = [:]
    @Locked var requests: [(url: URL, headers: [String: String])] = []
    @Locked var posts: [(url: URL, headers: [String: String], body: Data)] = []
    @Locked var isOffline = false
    /// Runs once inside the next post, before it answers: what the app does while a batch is on its way.
    @Locked var whilePosting: (() async -> Void)?

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        $stubs.mutate { $0[url] = Stub(status: status, headers: headers, body: body) }
    }

    func stubJson<T: Encodable>(_ url: String, _ value: T, status: Int = 200, headers: [String: String] = [:]) {
        stub(url, status: status, headers: headers, body: try! Json.encoder.encode(value))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse {
        $requests.mutate { $0.append((url, headers)) }
        if isOffline { throw URLError(.notConnectedToInternet) }
        guard let stub = stubs[url.absoluteString] else { return HttpResponse(status: 404, headers: [:], body: Data()) }
        return HttpResponse(status: stub.status, headers: stub.headers, body: stub.body)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse {
        $posts.mutate { $0.append((url, headers, body)) }
        if let whilePosting = whilePosting {
            self.whilePosting = nil
            await whilePosting()
        }
        if isOffline { throw URLError(.notConnectedToInternet) }
        // A post no test stubbed gets no answer, which keeps the outbox: a 404 would refuse the batch and drop its events.
        guard let stub = stubs[url.absoluteString] else { throw URLError(.cannotConnectToHost) }
        return HttpResponse(status: stub.status, headers: stub.headers, body: stub.body)
    }

    func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws {
        $requests.mutate { $0.append((url, [:])) }
        if isOffline { throw URLError(.notConnectedToInternet) }
        guard let stub = stubs[url.absoluteString], stub.status == 200 else { throw HttpStatusError(status: stubs[url.absoluteString]?.status ?? 404) }
        guard stub.body.count <= maximumBytes else { throw DownloadFailure.downloadFailed("\(url.lastPathComponent) is larger than its \(maximumBytes) bytes") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stub.body.write(to: file)
        progress(stub.body.count, stub.body.count)
    }
}

final class InMemoryStore: KeyValueStore {
    @Locked private(set) var values: [String: String] = [:]
    @Locked private(set) var integers: [String: Int] = [:]

    init() {}

    func string(forKey key: String) -> String? {
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        $values.mutate { $0[key] = value }
    }

    func integer(forKey key: String) -> Int? {
        return integers[key]
    }

    func set(_ value: Int?, forKey key: String) {
        $integers.mutate { $0[key] = value }
    }
}

final class FakeLoader: BundleLoader {
    let root: URL
    @Locked var persisted: String??
    @Locked var loaded: [String?] = []
    @Locked var served: String?
    @Locked var isMetered = false
    /// Runs inside the next read of the served bundle: a host slow to answer while the start waits on it.
    @Locked var whileReadingServedBundle: (() -> Void)?

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

    /// Every host also records what it loads as the bundle for the next start.
    func loadServedBundle(bundleId: String?) {
        persistServedBundle(bundleId: bundleId)
        $loaded.mutate { $0.append(bundleId) }
        served = bundleId
    }

    func servedBundleId() -> String? {
        if let whileReadingServedBundle = whileReadingServedBundle {
            self.whileReadingServedBundle = nil
            whileReadingServedBundle()
        }
        return served
    }

    func isConnectionMetered() -> Bool {
        return isMetered
    }
}

final class FakeListener: CoreListener {
    @Locked var available: [UpdateAvailableEvent] = []
    @Locked var downloaded: [UpdateDownloadedEvent] = []
    @Locked var failed: [UpdateFailedEvent] = []
    @Locked var progress: [(String, Int, Int)] = []
    @Locked var rolledBack: [RolledBackEvent] = []

    func updateAvailable(_ event: UpdateAvailableEvent) { $available.mutate { $0.append(event) } }
    func updateDownloaded(_ event: UpdateDownloadedEvent) { $downloaded.mutate { $0.append(event) } }
    func updateFailed(_ event: UpdateFailedEvent) { $failed.mutate { $0.append(event) } }
    func downloadProgress(releaseId: String, downloadedBytes: Int, totalBytes: Int) { $progress.mutate { $0.append((releaseId, downloadedBytes, totalBytes)) } }
    func rolledBack(_ event: RolledBackEvent) { $rolledBack.mutate { $0.append(event) } }
}

final class ManualScheduler: Scheduler {
    final class Task: ScheduledTask {
        let seconds: TimeInterval
        let block: () async -> Void
        @Locked var isCancelled = false
        init(seconds: TimeInterval, block: @escaping () async -> Void) { self.seconds = seconds; self.block = block }
        func cancel() { isCancelled = true }
    }

    @Locked var tasks: [Task] = []

    func schedule(after seconds: TimeInterval, _ block: @escaping () async -> Void) -> ScheduledTask {
        let task = Task(seconds: seconds, block: block)
        $tasks.mutate { $0.append(task) }
        return task
    }

    /// Fires every pending task that is still alive, the way time would, and returns once each has run.
    func fire() async {
        var pending: [Task] = []
        $tasks.mutate { tasks in
            pending = tasks
            tasks = []
        }
        for task in pending where !task.isCancelled {
            await task.block()
        }
    }
}

final class FixedClock: Clock {
    @Locked var now: Date

    init(now: Date) {
        self.now = now
    }
}

final class InMemoryEmbeddedBundle: EmbeddedBundle {
    @Locked var files: [String: Data] = [:]

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
    static let goneChannelId = "c0000000-0000-4000-8000-0000000000ff"
    static let stagingChannelId = "c0000000-0000-4000-8000-000000000002"
    static let filesBaseUrl = "https://files.test"
    static let updatesBaseUrl = "https://updates.test"
    static let builtAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let embeddedIndexHtml = Data("<html>v1</html>".utf8)

    static func embeddedManifest() -> EmbeddedBundleManifest {
        return EmbeddedBundleManifest(appId: appId, bundleVersion: "1.0.0", files: [.init(path: "index.html", sha256: Hashing.sha256Hex(embeddedIndexHtml), sizeBytes: embeddedIndexHtml.count)], platforms: ["ios"])
    }

    static func configuration(installStrategy: InstallStrategy = .nextStart, mandatoryInstallStrategy: MandatoryInstallStrategy = .immediate, downloadStrategy: DownloadStrategy = .auto, autoCheck: Bool = false, readySignal: ReadySignal = .render, publicKeys: [DevicePublicKey] = [], fingerprint: String? = "fp1:abc", builtAt: Date = Fixture.builtAt, enabledInDebugBuilds: Bool = true, channelId: String? = Fixture.channelId, hasEmbeddedBundle: Bool = true, filesBaseUrl: String? = Fixture.filesBaseUrl, updatesBaseUrl: String? = Fixture.updatesBaseUrl) -> Configuration {
        var json: [String: Any] = [
            "appId": appId,
            "channelId": channelId as Any,
            "autoCheck": autoCheck,
            "checkInterval": 900,
            "downloadStrategy": downloadStrategy.rawValue,
            "installStrategy": installStrategy.rawValue,
            "mandatoryInstallStrategy": mandatoryInstallStrategy.rawValue,
            "installOnResumeAfter": 300,
            "readySignal": readySignal.rawValue,
            "readyTimeout": 10,
            "enabledInDebugBuilds": enabledInDebugBuilds,
            "publicKeys": publicKeys.map { ["der": $0.der, "keyId": $0.keyId] },
            "builtAt": Iso8601.format(builtAt),
            "fingerprint": fingerprint as Any,
            "embeddedBundleManifest": hasEmbeddedBundle ? try! JSONSerialization.jsonObject(with: try! Json.encoder.encode(embeddedManifest())) : NSNull(),
            "embeddedBundleId": hasEmbeddedBundle ? "embedded" : NSNull()
        ]
        json["filesBaseUrl"] = filesBaseUrl
        json["updatesBaseUrl"] = updatesBaseUrl
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
            PackEntry.file(sha256: sha256, body: try! Gzip.compress(content)),
            PackEntry.file(sha256: Hashing.sha256Hex(js), body: try! Gzip.compress(js))
        ])
        let manifest = BundleManifest(appId: appId, bundleVersion: "1.\(number).0", files: [.init(path: "index.html", sha256: sha256, sizeBytes: content.count), .init(path: "assets/app.js", sha256: Hashing.sha256Hex(js), sizeBytes: js.count)], platforms: ["ios"])
        let manifestJson = String(bytes: try! Json.encoder.encode(manifest), encoding: .utf8) ?? ""
        let envelope = ManifestEnvelope(bundleId: bundleId, createdAt: createdAt, manifest: manifestJson, pack: .init(url: "\(filesBaseUrl)/apps/\(appId)/bundles/\(bundleId)/pack", sizeBytes: pack.count))
        let release = IndexRelease(id: "r\(number)", number: number, createdAt: createdAt, isMandatory: isMandatory, notes: "notes \(number)", rollout: rollout, conditions: conditions, bundleId: bundleId, bundleVersion: manifest.bundleVersion, manifestUrl: "\(filesBaseUrl)/apps/\(appId)/bundles/\(bundleId)/manifest.json", manifestSha256: Hashing.sha256Hex(manifestJson), sizeBytes: content.count)
        return (release, manifest, envelope, pack)
    }

    static func index(sequence: Int, releases: [IndexRelease], revoked: [String] = [], isPaused: Bool = false, cappedAt: Date? = nil) -> ChannelIndex {
        return ChannelIndex(sequence: sequence, appId: appId, channelId: channelId, platform: "ios", isPaused: isPaused, cappedAt: cappedAt, revokedReleaseIds: revoked, releases: releases)
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

    func publish(_ releases: [(release: IndexRelease, manifest: BundleManifest, envelope: ManifestEnvelope, pack: Data)], sequence: Int, revoked: [String] = [], isPaused: Bool = false, cappedAt: Date? = nil, etag: String = "\"e1\"") {
        http.stubJson(Fixture.indexUrl(), Fixture.index(sequence: sequence, releases: releases.map { $0.release }, revoked: revoked, isPaused: isPaused, cappedAt: cappedAt), headers: ["ETag": etag])
        for entry in releases {
            http.stubJson(entry.release.manifestUrl, entry.envelope)
            http.stub(entry.envelope.pack.url, body: entry.pack)
        }
    }
}
