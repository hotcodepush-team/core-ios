import Foundation

public enum DownloadFailure: Error, Equatable {
    case contentMismatched(String)
    case downloadFailed(String)
    case manifestInvalid(String)
    case signatureInvalid(String)

    public var reason: FailedReason {
        switch self {
        case .contentMismatched: return .contentMismatched
        case .downloadFailed: return .downloadFailed
        case .manifestInvalid: return .manifestInvalid
        case .signatureInvalid: return .signatureInvalid
        }
    }

    public var message: String {
        switch self {
        case .contentMismatched(let message), .downloadFailed(let message), .manifestInvalid(let message), .signatureInvalid(let message): return message
        }
    }
}

public struct DownloadOutcome: Equatable {
    public let manifest: BundleManifest
    public let downloadSizeBytes: Int
    /// The kind of the pack that brought the missing files, `nil` when no file was missing.
    public let packKind: PackKind?
}

struct PackSource: Equatable {
    let url: String
    let sizeBytes: Int
    let kind: PackKind
}

struct PackOutcome: Equatable {
    let bytes: Int
    let kind: PackKind
}

// A pack that did not serve the download, with the failure the download ends in when no pack follows it.
struct PackFailure: Error {
    let downloadFailure: DownloadFailure
}

// What failed while a pack was unpacked: the bytes the pack brought, or a part of the device itself.
enum UnpackFailureKind {
    case content
    case device
    case memory
    case storage
}

/// Downloads the files of a release, verifies them and writes them to the file store.
public final class Downloader {
    static let retryPausesSeconds: [TimeInterval] = [1, 3]

    private let clock: Clock
    private let configuration: Configuration
    private let embedded: EmbeddedBundle
    private let files: FileStore
    private let http: HttpClient
    private let platform: String
    private let startBackgroundWork: (@escaping () async -> Void) -> Void
    private let temporaryDirectory: URL

    /// `startBackgroundWork` runs the request to the updates host, which no download waits for.
    public init(configuration: Configuration, platform: String, files: FileStore, embedded: EmbeddedBundle, http: HttpClient, clock: Clock, temporaryDirectory: URL, startBackgroundWork: @escaping (@escaping () async -> Void) -> Void) {
        self.clock = clock
        self.configuration = configuration
        self.platform = platform
        self.files = files
        self.embedded = embedded
        self.http = http
        self.startBackgroundWork = startBackgroundWork
        self.temporaryDirectory = temporaryDirectory
    }

    /// Downloads the files the device lacks for a release and writes its manifest.
    /// `baseBundleId` is the bundle the device runs, `nil` without a base.
    public func downloadRelease(_ target: IndexRelease, baseBundleId: String?, progress: @escaping (Int, Int) -> Void) async throws -> DownloadOutcome {
        let (envelope, manifest) = try await fetchBundleManifest(target)
        let missing = resolveMissingFiles(manifest)
        let sources = resolvePackSources(envelope, baseBundleId: baseBundleId, missingFileCount: missing.count)
        try verifyFreeSpace(forBytes: missing.reduce(0) { $0 + $1.sizeBytes } + (sources.map(\.sizeBytes).max() ?? 0))
        if let deltaRouteUrl = resolveDeltaRouteUrl(envelope, baseBundleId: baseBundleId, missingFileCount: missing.count) {
            startBackgroundWork { await self.fetchDeltaRoute(deltaRouteUrl) }
        }
        let pack = sources.isEmpty ? nil : try await downloadPack(from: sources, bundleId: envelope.bundleId, missingFiles: missing, progress: progress)
        try files.writeManifest(manifest, bundleId: envelope.bundleId)
        return DownloadOutcome(manifest: manifest, downloadSizeBytes: pack?.bytes ?? 0, packKind: pack?.kind)
    }

    func fetchBundleManifest(_ target: IndexRelease) async throws -> (envelope: ManifestEnvelope, manifest: BundleManifest) {
        let url = try resolvePinnedUrl(target.manifestUrl)
        let response: HttpResponse
        do {
            response = try await fetchWithRetries {
                let fetchedResponse = try await http.get(url, headers: [:])
                guard fetchedResponse.status == 200 else { throw HttpStatusError(status: fetchedResponse.status) }
                return fetchedResponse
            }
        } catch let refusal as HttpStatusError {
            throw DownloadFailure.downloadFailed("HTTP \(refusal.status) for the manifest")
        } catch {
            throw DownloadFailure.downloadFailed("The manifest could not be fetched: \(error.localizedDescription)")
        }
        guard let envelope = try? Json.decoder.decode(ManifestEnvelope.self, from: response.body), let manifest = try? envelope.decodeManifest() else {
            throw DownloadFailure.manifestInvalid("The manifest could not be parsed")
        }
        try verifyManifestSignature(envelope, expectedSha256: target.manifestSha256)
        guard envelope.bundleId == target.bundleId else { throw DownloadFailure.manifestInvalid("The manifest names another bundle") }
        guard manifest.isForDevice(appId: configuration.appId, platform: platform) else {
            throw DownloadFailure.manifestInvalid("The manifest is for another app or does not list \(platform)")
        }
        try verifyPackUrlsPinned(envelope)
        return (envelope, manifest)
    }

    // The full pack can follow a delta that already wrote files, so every pack URL is checked before the first byte.
    private func verifyPackUrlsPinned(_ envelope: ManifestEnvelope) throws {
        for url in [envelope.pack.url] + envelope.deltas.map(\.url) {
            _ = try resolvePinnedUrl(url)
        }
    }

    // A manifest refused here costs no byte of the bundle.
    func verifyManifestSignature(_ envelope: ManifestEnvelope, expectedSha256: String) throws {
        let actual = Hashing.sha256Hex(envelope.manifest)
        guard actual == expectedSha256 else { throw DownloadFailure.manifestInvalid("The manifest's hash does not match the index") }
        guard !configuration.publicKeys.isEmpty else { return }
        do {
            try SignatureVerifier.verifyManifestSignature(envelope, publicKeys: configuration.publicKeys)
        } catch let refusal as SignatureRefusal {
            throw DownloadFailure.signatureInvalid(Downloader.resolveSignatureRefusalMessage(refusal, keyId: envelope.signature?.keyId ?? ""))
        }
    }

    static func resolveSignatureRefusalMessage(_ refusal: SignatureRefusal, keyId: String) -> String {
        switch refusal {
        case .unsigned: return "The manifest is unsigned and the app accepts only signed manifests"
        case .unknownScheme: return "The manifest's signature is not of the scheme \(SignatureVerifier.scheme)"
        case .unlistedKey: return "The manifest is signed by a key the app does not list: \(keyId)"
        case .unimportableKey: return "The app's configuration is wrong: the system cannot import the public key \(keyId) of the resource file as an RSA key"
        case .weakKey: return "The public key \(keyId) is smaller than \(SignatureVerifier.minimumKeyBits) bits"
        case .mismatch: return "The manifest's signature does not verify under the public key \(keyId)"
        }
    }

    func resolveMissingFiles(_ manifest: BundleManifest) -> [BundleManifest.File] {
        return manifest.files.filter { !files.hasFile(sha256: $0.sha256) && !embedded.has(sha256: $0.sha256) }
    }

    // A device with a base tries a delta even for one missing file, so the main bundle can arrive as a patch.
    // Only a listed delta is used, never a URL guessed on the files host.
    func resolvePackSources(_ envelope: ManifestEnvelope, baseBundleId: String?, missingFileCount: Int) -> [PackSource] {
        guard missingFileCount > 0 else { return [] }
        let fullPack = PackSource(url: envelope.pack.url, sizeBytes: envelope.pack.sizeBytes, kind: .full)
        guard let listedDelta = resolveListedDelta(envelope, baseBundleId: baseBundleId) else { return [fullPack] }
        return [PackSource(url: listedDelta.url, sizeBytes: listedDelta.sizeBytes, kind: .delta), fullPack]
    }

    func resolveDeltaRouteUrl(_ envelope: ManifestEnvelope, baseBundleId: String?, missingFileCount: Int) -> String? {
        guard missingFileCount > 0, let baseBundleId = baseBundleId, resolveListedDelta(envelope, baseBundleId: baseBundleId) == nil else { return nil }
        return "\(configuration.updatesBaseUrl)/v1/apps/\(configuration.appId)/bundles/\(envelope.bundleId)/deltas/\(baseBundleId)"
    }

    private func resolveListedDelta(_ envelope: ManifestEnvelope, baseBundleId: String?) -> ManifestEnvelope.Delta? {
        return envelope.deltas.first { $0.baseBundleId == baseBundleId }
    }

    func verifyFreeSpace(forBytes requiredBytes: Int) throws {
        guard let availableBytes = files.availableBytes(), availableBytes < requiredBytes else { return }
        throw DownloadFailure.downloadFailed("The download needs \(requiredBytes) bytes and \(availableBytes) are free")
    }

    // The request is sent once and never retried, and no failure of it changes the download.
    private func fetchDeltaRoute(_ urlString: String) async {
        guard let url = try? resolvePinnedUrl(urlString) else { return }
        try? await http.send(url)
    }

    // The verdict comes from what each pack stored, never from a second look at the device.
    // A failure of the device itself ends the download, since the next pack would fail the same way.
    func downloadPack(from sources: [PackSource], bundleId: String, missingFiles: [BundleManifest.File], progress: @escaping (Int, Int) -> Void) async throws -> PackOutcome {
        var missingFilesByHash = Dictionary(missingFiles.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        var lastFailure: PackFailure?
        for source in sources {
            do {
                let bytes = try await downloadPackEntries(source, bundleId: bundleId, missingFilesByHash: &missingFilesByHash, progress: progress)
                return PackOutcome(bytes: bytes, kind: source.kind)
            } catch let failure as PackFailure {
                lastFailure = failure
                if source.kind == .delta {
                    try? FileManager.default.removeItem(at: resolvePackFile(source, bundleId: bundleId))
                }
            }
        }
        throw lastFailure?.downloadFailure ?? PlainError("A download needs a pack source")
    }

    func downloadPackEntries(_ source: PackSource, bundleId: String, missingFilesByHash: inout [String: BundleManifest.File], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let file = resolvePackFile(source, bundleId: bundleId)
        do {
            try await downloadPackFile(source, to: file, progress: progress)
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try readPackFile(file)
            guard data.count == source.sizeBytes else {
                throw DownloadFailure.contentMismatched("The pack holds \(data.count) of its \(source.sizeBytes) bytes")
            }
            try writePackEntries(of: data, missingFilesByHash: &missingFilesByHash)
            try verifyNoFileMissing(missingFilesByHash)
            return data.count
        } catch let mismatch as DownloadFailure where mismatch.reason == .contentMismatched {
            throw PackFailure(downloadFailure: mismatch)
        }
    }

    // Named by bundle and URL, so a later attempt or cycle resumes it. The one running cycle keeps two downloads from sharing it.
    func resolvePackFile(_ source: PackSource, bundleId: String) -> URL {
        return temporaryDirectory.appendingPathComponent("\(bundleId)-\(Hashing.sha256Hex(source.url).prefix(16)).pack")
    }

    private func downloadPackFile(_ source: PackSource, to file: URL, progress: @escaping (Int, Int) -> Void) async throws {
        let url = try resolvePinnedUrl(source.url)
        do {
            try await fetchWithRetries { try await http.download(url, to: file, maximumBytes: source.sizeBytes, progress: progress) }
        } catch let refusal as HttpStatusError {
            throw PackFailure(downloadFailure: .downloadFailed("HTTP \(refusal.status) for the pack"))
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            // The client gives a failure of the device its own type, so every other error is a transport failure.
            throw PackFailure(downloadFailure: .downloadFailed("The pack could not be downloaded: \(error.localizedDescription)"))
        }
    }

    private func readPackFile(_ file: URL) throws -> Data {
        do {
            return try Data(contentsOf: file, options: .alwaysMapped)
        } catch {
            throw Downloader.resolveUnpackFailure(.device, cause: error)
        }
    }

    private func writePackEntries(of data: Data, missingFilesByHash: inout [String: BundleManifest.File]) throws {
        do {
            try PackReader.forEachEntry(in: data) { entry in
                switch entry {
                case .file(let sha256, let body):
                    guard let missing = missingFilesByHash[sha256] else { return }
                    try writeInflatedFile(body, sha256: sha256, maximumBytes: missing.sizeBytes)
                    missingFilesByHash[sha256] = nil
                case .patch(let fromSha256, let toSha256, let body):
                    guard let missing = missingFilesByHash[toSha256] else { return }
                    // A patch that does not apply, whatever failed, leaves its file missing, so the delta gives way to the full pack.
                    if (try? applyPatch(body, from: fromSha256, to: toSha256, maximumBytes: missing.sizeBytes)) != nil {
                        missingFilesByHash[toSha256] = nil
                    }
                }
            }
        } catch {
            throw Downloader.resolveUnpackFailure(Downloader.resolveUnpackFailureKind(of: error), cause: error)
        }
    }

    // Only wrong bytes are the pack's fault. Every other failure is the device's own.
    private static func resolveUnpackFailureKind(of error: Error) -> UnpackFailureKind {
        switch error {
        case is PackReader.Failure, FileStore.Failure.hashMismatch, Gzip.Failure.corrupt, Gzip.Failure.tooLarge:
            return .content
        case Gzip.Failure.outOfMemory:
            return .memory
        case Gzip.Failure.unwritable, is CocoaError:
            return .storage
        default:
            return .device
        }
    }

    private static func resolveUnpackFailure(_ kind: UnpackFailureKind, cause: Error) -> DownloadFailure {
        switch kind {
        case .content:
            return .contentMismatched("The pack did not verify: \(cause)")
        case .device:
            return .downloadFailed("The device failed while it unpacked the pack: \(cause.localizedDescription)")
        case .memory:
            return .downloadFailed("The device ran out of memory while it unpacked the pack")
        case .storage:
            return .downloadFailed("The pack could not be written to the device's storage: \(cause.localizedDescription)")
        }
    }

    private func verifyNoFileMissing(_ missingFilesByHash: [String: BundleManifest.File]) throws {
        guard let missing = missingFilesByHash.values.min(by: { $0.path < $1.path }) else { return }
        throw DownloadFailure.contentMismatched("The pack lacks the file \(missing.path)")
    }

    private func writeInflatedFile(_ body: Data, sha256: String, maximumBytes: Int) throws {
        let inflated = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).inflating")
        defer { try? FileManager.default.removeItem(at: inflated) }
        try Gzip.decompress(body, to: inflated, maximumBytes: maximumBytes)
        try files.writeFile(at: inflated, sha256: sha256)
    }

    func applyPatch(_ patch: Data, from fromSha256: String, to toSha256: String, maximumBytes: Int) throws {
        let directory = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).patching", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let patchFile = directory.appendingPathComponent("patch")
        let patchedFile = directory.appendingPathComponent("patched")
        try patch.write(to: patchFile)
        try Bspatch.apply(patchFile, to: try preparePatchBase(fromSha256, in: directory), writingTo: patchedFile, maximumBytes: maximumBytes)
        try files.writeFile(at: patchedFile, sha256: toSha256)
    }

    private func preparePatchBase(_ sha256: String, in directory: URL) throws -> URL {
        if files.hasFile(sha256: sha256) {
            return files.fileURL(sha256: sha256)
        }
        guard embedded.has(sha256: sha256) else { throw CocoaError(.fileNoSuchFile) }
        let base = directory.appendingPathComponent("base")
        try embedded.copyFile(sha256: sha256, to: base)
        return base
    }

    // The SDK fetches from its configured hosts and nowhere else.
    func resolvePinnedUrl(_ string: String) throws -> URL {
        guard configuration.isUrlOnConfiguredHost(string), let url = URL(string: string) else {
            throw DownloadFailure.manifestInvalid("\(string) is not on a configured host")
        }
        return url
    }

    // Any answer but a transient failure is final at once: after a 404 or a 410 the object will not appear.
    private func fetchWithRetries<Fetched>(_ attempt: () async throws -> Fetched) async throws -> Fetched {
        for pauseSeconds in Downloader.retryPausesSeconds {
            do {
                return try await attempt()
            } catch where Downloader.isTransientFailure(error) {
                try await clock.sleep(seconds: pauseSeconds)
            }
        }
        return try await attempt()
    }

    // A dropped connection that cuts the body short is a `URLError` too.
    private static func isTransientFailure(_ error: Error) -> Bool {
        if let refusal = error as? HttpStatusError {
            return (500...599).contains(refusal.status)
        }
        if let failure = error as? URLError {
            return failure.code != .cancelled
        }
        return false
    }
}
