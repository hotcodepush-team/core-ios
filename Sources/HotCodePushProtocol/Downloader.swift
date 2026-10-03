import Foundation

public enum DownloadFailure: Error, Equatable {
    case invalidSignature(String)
    case verificationFailed(String)
    case downloadFailed(String)

    public var reason: FailedReason {
        switch self {
        case .invalidSignature: return .invalidSignature
        case .verificationFailed: return .verificationFailed
        case .downloadFailed: return .downloadFailed
        }
    }

    public var message: String {
        switch self {
        case .invalidSignature(let message), .verificationFailed(let message), .downloadFailed(let message): return message
        }
    }
}

public struct DownloadOutcome: Equatable {
    public let manifest: BundleManifest
    public let bytes: Int
    public let packKind: PackKind
}

/// Manifest, signature, missing files, pack, verification, files to disk — each step one function.
public final class Downloader {
    private let configuration: Configuration
    private let embedded: EmbeddedBundle
    private let files: FileStore
    private let http: HttpClient
    private let temporaryDirectory: URL

    public init(configuration: Configuration, files: FileStore, embedded: EmbeddedBundle, http: HttpClient, temporaryDirectory: URL) {
        self.configuration = configuration
        self.files = files
        self.embedded = embedded
        self.http = http
        self.temporaryDirectory = temporaryDirectory
    }

    public func downloadRelease(_ target: IndexRelease, currentBundleId: String?, progress: @escaping (Int, Int) -> Void) async throws -> DownloadOutcome {
        let (envelope, manifest) = try await fetchBundleManifest(target)
        let missing = resolveMissingFiles(manifest)
        let pack = missing.isEmpty ? nil : resolvePack(envelope, currentBundleId: currentBundleId, missing: missing)
        try verifyFreeSpace(forBytes: missing.reduce(0) { $0 + $1.sizeBytes } + (pack?.source.sizeBytes ?? 0))
        var bytes = 0
        var packKind = PackKind.files
        if let pack = pack {
            let wanted = Dictionary(missing.map { ($0.sha256, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
            bytes += try await downloadPack(pack.source, bundleId: envelope.bundleId, wanted: wanted, progress: progress)
            packKind = pack.kind
        }
        for file in resolveMissingFiles(manifest) {
            bytes += try await downloadFile(file)
        }
        try files.writeManifest(manifest, bundleId: envelope.bundleId)
        return DownloadOutcome(manifest: manifest, bytes: bytes, packKind: packKind)
    }

    /// The envelope with its manifest decoded, once the manifest's bytes match the index and the envelope names the release's bundle.
    func fetchBundleManifest(_ target: IndexRelease) async throws -> (envelope: ManifestEnvelope, manifest: BundleManifest) {
        let url = try resolvePinnedUrl(target.manifestUrl)
        let response: HttpResponse
        do {
            response = try await http.get(url, headers: [:])
        } catch {
            throw DownloadFailure.downloadFailed("The manifest could not be fetched: \(error.localizedDescription)")
        }
        guard response.status == 200 else { throw DownloadFailure.downloadFailed("HTTP \(response.status) for the manifest") }
        guard let envelope = try? Json.decoder.decode(ManifestEnvelope.self, from: response.body), let manifest = try? envelope.decodeManifest() else {
            throw DownloadFailure.verificationFailed("The manifest could not be parsed")
        }
        try verifyManifestSignature(envelope, expectedSha256: target.manifestSha256)
        guard envelope.bundleId == target.bundleId else { throw DownloadFailure.verificationFailed("The manifest names another bundle") }
        return (envelope, manifest)
    }

    /// The manifest's bytes against the index's hash, then, once the app carries public keys, against the customer's signature:
    /// an unsigned or wrongly signed manifest is refused before a byte of the bundle is fetched.
    func verifyManifestSignature(_ envelope: ManifestEnvelope, expectedSha256: String) throws {
        let actual = Hashing.sha256Hex(envelope.manifest)
        guard actual == expectedSha256 else { throw DownloadFailure.verificationFailed("The manifest's hash does not match the index") }
        guard !configuration.publicKeys.isEmpty else { return }
        guard envelope.signature != nil else { throw DownloadFailure.invalidSignature("The manifest is unsigned and the app accepts only signed bundles") }
        guard Signatures.verifyManifestSignature(envelope, publicKeys: configuration.publicKeys) else {
            throw DownloadFailure.invalidSignature("The manifest's signature does not verify against the app's public keys")
        }
    }

    func resolveMissingFiles(_ manifest: BundleManifest) -> [BundleManifest.File] {
        return manifest.files.filter { !files.hasFile(sha256: $0.sha256) && !embedded.has(sha256: $0.sha256) }
    }

    /// The delta pack against the running bundle where one exists, the full pack otherwise; nothing when the pack would cost more than the files.
    func resolvePack(_ envelope: ManifestEnvelope, currentBundleId: String?, missing: [BundleManifest.File]) -> (source: ManifestEnvelope.Pack, kind: PackKind)? {
        if let currentBundleId = currentBundleId, let delta = envelope.deltas.first(where: { $0.baseBundleId == currentBundleId }) {
            return (.init(url: delta.url, sizeBytes: delta.sizeBytes), .delta)
        }
        if missing.count > 1 {
            return (envelope.pack, .full)
        }
        return nil
    }

    /// The download needs its bytes on disk at its peak: every missing file and the pack they arrive in.
    func verifyFreeSpace(forBytes requiredBytes: Int) throws {
        guard let availableBytes = files.availableBytes(), availableBytes < requiredBytes else { return }
        throw DownloadFailure.downloadFailed("The download needs \(requiredBytes) bytes and \(availableBytes) are free")
    }

    /// Streams the pack to disk, resuming what an earlier attempt left and never past its size in the manifest, then inflates each
    /// wanted entry up to its file's size: an entry is always the gzip bytes the bucket serves.
    func downloadPack(_ source: ManifestEnvelope.Pack, bundleId: String, wanted: [String: Int], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let url = try resolvePinnedUrl(source.url)
        let file = temporaryDirectory.appendingPathComponent("\(bundleId)-\(Hashing.sha256Hex(source.url).prefix(16)).pack")
        do {
            try await http.download(url, to: file, maximumBytes: source.sizeBytes, progress: progress)
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.downloadFailed("The pack could not be downloaded: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw DownloadFailure.downloadFailed("The pack could not be read") }
        guard data.count == source.sizeBytes else { throw DownloadFailure.verificationFailed("The pack holds \(data.count) of its \(source.sizeBytes) bytes") }
        do {
            try PackReader.forEachEntry(in: data) { entry in
                guard let sizeBytes = wanted[entry.sha256] else { return }
                try files.writeFile(try Gzip.decompress(entry.body, maximumBytes: sizeBytes), sha256: entry.sha256)
            }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.verificationFailed("The pack did not verify: \(error)")
        }
        return data.count
    }

    /// The URL of a manifest, pack or delta only when it is on a configured host: the SDK fetches from our hosts and nowhere else.
    func resolvePinnedUrl(_ string: String) throws -> URL {
        let isOnConfiguredHost = [configuration.filesBaseUrl, configuration.updatesBaseUrl].contains { string.hasPrefix("\($0)/") }
        guard isOnConfiguredHost, let url = URL(string: string) else {
            throw DownloadFailure.verificationFailed("\(string) is not on a configured host")
        }
        return url
    }

    /// One file through the same bounded stream as the pack, never past its size in the manifest; the HTTP client already
    /// decoded the gzip the bucket serves, so the body is the content, whatever bytes it starts with.
    func downloadFile(_ file: BundleManifest.File) async throws -> Int {
        guard let url = URL(string: "\(configuration.filesBaseUrl)/apps/\(configuration.appId)/files/\(file.sha256)") else { throw DownloadFailure.downloadFailed("Invalid file URL") }
        let temporary = temporaryDirectory.appendingPathComponent("\(file.sha256).file")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await http.download(url, to: temporary, maximumBytes: file.sizeBytes) { _, _ in }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure.downloadFailed("The file \(file.path) could not be downloaded: \(error.localizedDescription)")
        }
        guard let content = try? Data(contentsOf: temporary) else { throw DownloadFailure.downloadFailed("The file \(file.path) could not be read") }
        do {
            try files.writeFile(content, sha256: file.sha256)
        } catch {
            throw DownloadFailure.verificationFailed("The file \(file.path) did not match its hash")
        }
        return content.count
    }
}
