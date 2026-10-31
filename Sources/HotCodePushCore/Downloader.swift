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
    public let packKind: PackKind
}

struct PackSource: Equatable {
    let url: String
    let sizeBytes: Int?
    let packBytesLimit: Int
    let kind: PackKind
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
    private let temporaryDirectory: URL

    public init(configuration: Configuration, platform: String, files: FileStore, embedded: EmbeddedBundle, http: HttpClient, clock: Clock, temporaryDirectory: URL) {
        self.clock = clock
        self.configuration = configuration
        self.platform = platform
        self.files = files
        self.embedded = embedded
        self.http = http
        self.temporaryDirectory = temporaryDirectory
    }

    /// Downloads the files the device lacks for a release and writes its manifest.
    /// `baseBundleId` is the bundle the device runs, `nil` without a base.
    public func downloadRelease(_ target: IndexRelease, baseBundleId: String?, progress: @escaping (Int, Int) -> Void) async throws -> DownloadOutcome {
        let (envelope, manifest) = try await fetchBundleManifest(target)
        let missing = resolveMissingFiles(manifest)
        let pack = resolvePack(envelope, baseBundleId: baseBundleId, missingFileCount: missing.count)
        try verifyFreeSpace(forBytes: missing.reduce(0) { $0 + $1.sizeBytes } + (pack?.packBytesLimit ?? 0))
        var downloadSizeBytes = 0
        var packKind = PackKind.files
        if let pack = pack {
            let wanted = Dictionary(missing.map { ($0.sha256, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
            (downloadSizeBytes, packKind) = try await downloadPack(pack, envelope: envelope, wanted: wanted, progress: progress)
        }
        for file in resolveMissingFiles(manifest) {
            downloadSizeBytes += try await downloadFile(file)
        }
        try files.writeManifest(manifest, bundleId: envelope.bundleId)
        return DownloadOutcome(manifest: manifest, downloadSizeBytes: downloadSizeBytes, packKind: packKind)
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
            throw DownloadFailure.manifestInvalid("The manifest is for another app or platform")
        }
        return (envelope, manifest)
    }

    // A manifest refused here costs no byte of the bundle.
    func verifyManifestSignature(_ envelope: ManifestEnvelope, expectedSha256: String) throws {
        let actual = Hashing.sha256Hex(envelope.manifest)
        guard actual == expectedSha256 else { throw DownloadFailure.manifestInvalid("The manifest's hash does not match the index") }
        guard !configuration.publicKeys.isEmpty else { return }
        do {
            try Signatures.verifyManifestSignature(envelope, publicKeys: configuration.publicKeys)
        } catch let refusal as SignatureRefusal {
            throw DownloadFailure.signatureInvalid(Downloader.describe(refusal, keyId: envelope.signature?.keyId ?? ""))
        }
    }

    static func describe(_ refusal: SignatureRefusal, keyId: String) -> String {
        switch refusal {
        case .unsigned: return "The manifest is unsigned and the app accepts only signed bundles"
        case .unknownScheme: return "The manifest's signature is not of the scheme \(Signatures.scheme)"
        case .unlistedKey: return "The manifest is signed by a key the app does not list: \(keyId)"
        case .unimportableKey: return "The app's configuration is wrong: the system cannot import the public key \(keyId) of the resource file as an RSA key"
        case .weakKey: return "The public key \(keyId) is smaller than \(Signatures.minimumKeyBits) bits"
        case .mismatch: return "The manifest's signature does not verify under the public key \(keyId)"
        }
    }

    func resolveMissingFiles(_ manifest: BundleManifest) -> [BundleManifest.File] {
        return manifest.files.filter { !files.hasFile(sha256: $0.sha256) && !embedded.has(sha256: $0.sha256) }
    }

    // A device with a base takes a delta even for one missing file, so the main bundle arrives as a patch.
    // Only a listed delta or the streamed pack is used, never a URL guessed on the files host.
    func resolvePack(_ envelope: ManifestEnvelope, baseBundleId: String?, missingFileCount: Int) -> PackSource? {
        guard missingFileCount > 0 else { return nil }
        guard let baseBundleId = baseBundleId else { return resolveFullPack(envelope) }
        guard let listedDelta = envelope.deltas.first(where: { $0.baseBundleId == baseBundleId }) else { return resolveStreamedPack(envelope, baseBundleId: baseBundleId) }
        return PackSource(url: listedDelta.url, sizeBytes: listedDelta.sizeBytes, packBytesLimit: listedDelta.sizeBytes, kind: .delta)
    }

    // The updates host redirects to the full pack above twenty objects, and a download follows no redirect.
    // So any refusal of the streamed pack falls back to the full pack.
    func resolveFallbackPack(after source: PackSource, envelope: ManifestEnvelope) -> PackSource? {
        switch source.kind {
        case .delta, .files, .full:
            return nil
        case .streamed:
            return resolveFullPack(envelope)
        }
    }

    private func resolveFullPack(_ envelope: ManifestEnvelope) -> PackSource {
        return PackSource(url: envelope.pack.url, sizeBytes: envelope.pack.sizeBytes, packBytesLimit: envelope.pack.sizeBytes, kind: .full)
    }

    // Its length is known only as it arrives, but it never exceeds the full pack whose entries it shares.
    private func resolveStreamedPack(_ envelope: ManifestEnvelope, baseBundleId: String) -> PackSource {
        let url = "\(configuration.updatesBaseUrl)/v1/apps/\(configuration.appId)/bundles/\(envelope.bundleId)/deltas/\(baseBundleId)"
        return PackSource(url: url, sizeBytes: nil, packBytesLimit: envelope.pack.sizeBytes, kind: .streamed)
    }

    func verifyFreeSpace(forBytes requiredBytes: Int) throws {
        guard let availableBytes = files.availableBytes(), availableBytes < requiredBytes else { return }
        throw DownloadFailure.downloadFailed("The download needs \(requiredBytes) bytes and \(availableBytes) are free")
    }

    func downloadPack(_ source: PackSource, envelope: ManifestEnvelope, wanted: [String: Int], progress: @escaping (Int, Int) -> Void) async throws -> (bytes: Int, kind: PackKind) {
        do {
            return (try await downloadPackEntries(source, bundleId: envelope.bundleId, wanted: wanted, progress: progress), source.kind)
        } catch let refusal as HttpStatusError {
            guard let fallback = resolveFallbackPack(after: source, envelope: envelope) else {
                throw DownloadFailure.downloadFailed("HTTP \(refusal.status) for the pack")
            }
            return try await downloadPack(fallback, envelope: envelope, wanted: wanted, progress: progress)
        }
    }

    func downloadPackEntries(_ source: PackSource, bundleId: String, wanted: [String: Int], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let url = try resolvePinnedUrl(source.url)
        // Named by bundle and URL, so a later attempt or cycle resumes it. The one running cycle keeps two downloads from sharing it.
        let file = temporaryDirectory.appendingPathComponent("\(bundleId)-\(Hashing.sha256Hex(source.url).prefix(16)).pack")
        do {
            try await fetchWithRetries { try await http.download(url, to: file, maximumBytes: source.packBytesLimit, progress: progress) }
        } catch let failure as DownloadFailure {
            throw failure
        } catch let refusal as HttpStatusError {
            throw refusal
        } catch {
            throw DownloadFailure.downloadFailed("The pack could not be downloaded: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { throw DownloadFailure.downloadFailed("The pack could not be read") }
        if let sizeBytes = source.sizeBytes, data.count != sizeBytes {
            throw DownloadFailure.contentMismatched("The pack holds \(data.count) of its \(sizeBytes) bytes")
        }
        do {
            try PackReader.forEachEntry(in: data) { entry in
                switch entry {
                case .file(let sha256, let body):
                    guard let sizeBytes = wanted[sha256] else { return }
                    try writeInflatedFile(body, sha256: sha256, maximumBytes: sizeBytes)
                case .patch(let fromSha256, let toSha256, let body):
                    guard let sizeBytes = wanted[toSha256] else { return }
                    // A patch that does not apply leaves its file to the single-file fetch after the pack.
                    try? applyPatch(body, from: fromSha256, to: toSha256, maximumBytes: sizeBytes)
                }
            }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.contentMismatched("The pack did not verify: \(error)")
        }
        return data.count
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
        guard configuration.isOnConfiguredHost(string), let url = URL(string: string) else {
            throw DownloadFailure.manifestInvalid("\(string) is not on a configured host")
        }
        return url
    }

    func downloadFile(_ file: BundleManifest.File) async throws -> Int {
        guard let url = URL(string: "\(configuration.filesBaseUrl)/apps/\(configuration.appId)/files/\(file.sha256)") else { throw DownloadFailure.downloadFailed("Invalid file URL") }
        let temporary = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).file")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await fetchWithRetries {
                // The HTTP client decodes the gzip the bucket serves, so a byte range could not continue it and every attempt starts over.
                try? FileManager.default.removeItem(at: temporary)
                try await http.download(url, to: temporary, maximumBytes: file.sizeBytes) { _, _ in }
            }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.downloadFailed("The file \(file.path) could not be downloaded: \(error.localizedDescription)")
        }
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? Int else {
            throw DownloadFailure.downloadFailed("The file \(file.path) could not be read")
        }
        do {
            try files.writeFile(at: temporary, sha256: file.sha256)
        } catch {
            throw DownloadFailure.contentMismatched("The file \(file.path) did not match its hash")
        }
        return bytes
    }

    // Any answer but a transient failure is final at once: after a 404 or a 410 the object will not appear.
    private func fetchWithRetries<Fetched>(_ attempt: () async throws -> Fetched) async throws -> Fetched {
        for pauseSeconds in Downloader.retryPausesSeconds {
            do {
                return try await attempt()
            } catch where Downloader.isTransient(error) {
                try await clock.sleep(seconds: pauseSeconds)
            }
        }
        return try await attempt()
    }

    // A dropped connection that cuts the body short is a `URLError` too.
    private static func isTransient(_ error: Error) -> Bool {
        if let refusal = error as? HttpStatusError {
            return (500...599).contains(refusal.status)
        }
        if let failure = error as? URLError {
            return failure.code != .cancelled
        }
        return false
    }
}
