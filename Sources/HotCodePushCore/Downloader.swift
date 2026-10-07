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
    public let bytes: Int
    public let packKind: PackKind
}

/// Where a pack comes from: its URL, its size where the envelope states one, the most bytes it may hold and how the bytes arrive.
struct PackSource: Equatable {
    let url: String
    let sizeBytes: Int?
    let maximumBytes: Int
    let kind: PackKind
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
        try verifyFreeSpace(forBytes: missing.reduce(0) { $0 + $1.sizeBytes } + (pack?.maximumBytes ?? 0))
        var bytes = 0
        var packKind = PackKind.files
        if let pack = pack {
            let wanted = Dictionary(missing.map { ($0.sha256, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
            (bytes, packKind) = try await downloadPack(pack, envelope: envelope, wanted: wanted, progress: progress)
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
            throw DownloadFailure.manifestInvalid("The manifest could not be parsed")
        }
        try verifyManifestSignature(envelope, expectedSha256: target.manifestSha256)
        guard envelope.bundleId == target.bundleId else { throw DownloadFailure.manifestInvalid("The manifest names another bundle") }
        return (envelope, manifest)
    }

    /// The manifest's bytes against the index's hash, then, once the app carries public keys, against the customer's signature:
    /// an unsigned or wrongly signed manifest is refused before a byte of the bundle is fetched.
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

    /// The sentence behind a refused signature; an unimportable key is the app's configuration, and the sentence says so.
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

    /// The delta pack the bucket holds against the running bundle; for any other base the device runs, the delta the updates host
    /// streams, never larger than the full pack whose entries it shares; without a base the full pack; nothing when one file is cheaper than a pack.
    func resolvePack(_ envelope: ManifestEnvelope, currentBundleId: String?, missing: [BundleManifest.File]) -> PackSource? {
        if let currentBundleId = currentBundleId, let delta = envelope.deltas.first(where: { $0.baseBundleId == currentBundleId }) {
            return PackSource(url: delta.url, sizeBytes: delta.sizeBytes, maximumBytes: delta.sizeBytes, kind: .delta)
        }
        guard missing.count > 1 else { return nil }
        if let currentBundleId = currentBundleId {
            let url = "\(configuration.updatesBaseUrl)/v1/apps/\(configuration.appId)/bundles/\(envelope.bundleId)/deltas/\(currentBundleId)"
            return PackSource(url: url, sizeBytes: nil, maximumBytes: envelope.pack.sizeBytes, kind: .streamed)
        }
        return resolveFullPack(envelope)
    }

    private func resolveFullPack(_ envelope: ManifestEnvelope) -> PackSource {
        return PackSource(url: envelope.pack.url, sizeBytes: envelope.pack.sizeBytes, maximumBytes: envelope.pack.sizeBytes, kind: .full)
    }

    /// The download needs its bytes on disk at its peak: every missing file and the pack they arrive in.
    func verifyFreeSpace(forBytes requiredBytes: Int) throws {
        guard let availableBytes = files.availableBytes(), availableBytes < requiredBytes else { return }
        throw DownloadFailure.downloadFailed("The download needs \(requiredBytes) bytes and \(availableBytes) are free")
    }

    /// The pack's wanted entries in the store and how they arrived. A streamed delta the updates host does not serve — its redirect
    /// to the full pack above twenty objects or for a base the bucket no longer knows, a limit, an error — gives way to the full pack: slower, never failed.
    func downloadPack(_ source: PackSource, envelope: ManifestEnvelope, wanted: [String: Int], progress: @escaping (Int, Int) -> Void) async throws -> (bytes: Int, kind: PackKind) {
        do {
            return (try await downloadPackEntries(source, bundleId: envelope.bundleId, wanted: wanted, progress: progress), source.kind)
        } catch let refusal as HttpStatusError {
            guard source.kind == .streamed else { throw DownloadFailure.downloadFailed("HTTP \(refusal.status) for the pack") }
            return try await downloadPack(resolveFullPack(envelope), envelope: envelope, wanted: wanted, progress: progress)
        }
    }

    /// Streams the pack to disk, resuming what an earlier attempt left and never past its bound, then inflates each
    /// wanted file entry up to its file's size, an entry always the gzip bytes the bucket serves, and applies each patch
    /// entry to a wanted file. A patch that does not apply leaves its file missing, fetched whole after the pack.
    func downloadPackEntries(_ source: PackSource, bundleId: String, wanted: [String: Int], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let url = try resolvePinnedUrl(source.url)
        let file = temporaryDirectory.appendingPathComponent("\(bundleId)-\(Hashing.sha256Hex(source.url).prefix(16)).pack")
        do {
            try await http.download(url, to: file, maximumBytes: source.maximumBytes, progress: progress)
        } catch let failure as DownloadFailure {
            throw failure
        } catch let refusal as HttpStatusError {
            throw refusal
        } catch {
            throw DownloadFailure.downloadFailed("The pack could not be downloaded: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw DownloadFailure.downloadFailed("The pack could not be read") }
        if let sizeBytes = source.sizeBytes, data.count != sizeBytes {
            throw DownloadFailure.contentMismatched("The pack holds \(data.count) of its \(sizeBytes) bytes")
        }
        do {
            try PackReader.forEachEntry(in: data) { entry in
                switch entry {
                case .file(let sha256, let body):
                    guard let sizeBytes = wanted[sha256] else { return }
                    try files.writeFile(try Gzip.decompress(body, maximumBytes: sizeBytes), sha256: sha256)
                case .patch(let fromSha256, let toSha256, let body):
                    guard let sizeBytes = wanted[toSha256] else { return }
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

    /// Writes the file `toSha256` from the patch and the held file `fromSha256`; the store refuses bytes of another hash.
    func applyPatch(_ patch: Data, from fromSha256: String, to toSha256: String, maximumBytes: Int) throws {
        let directory = temporaryDirectory.appendingPathComponent("\(toSha256).patching", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let patchFile = directory.appendingPathComponent("patch")
        let patchedFile = directory.appendingPathComponent("patched")
        try patch.write(to: patchFile)
        try Bspatch.apply(patchFile, to: try preparePatchBase(fromSha256, in: directory), writingTo: patchedFile, maximumBytes: maximumBytes)
        try files.writeFile(try Data(contentsOf: patchedFile, options: .mappedIfSafe), sha256: toSha256)
    }

    /// The held file a patch starts from: the store's in place, the embedded bundle's copied beside the patch.
    private func preparePatchBase(_ sha256: String, in directory: URL) throws -> URL {
        if files.hasFile(sha256: sha256) {
            return files.fileURL(sha256: sha256)
        }
        guard embedded.has(sha256: sha256) else { throw CocoaError(.fileNoSuchFile) }
        let base = directory.appendingPathComponent("base")
        try embedded.copyFile(sha256: sha256, to: base)
        return base
    }

    /// The URL of a manifest, pack or delta only when it is on a configured host: the SDK fetches from our hosts and nowhere else.
    func resolvePinnedUrl(_ string: String) throws -> URL {
        let isOnConfiguredHost = [configuration.filesBaseUrl, configuration.updatesBaseUrl].contains { string.hasPrefix("\($0)/") }
        guard isOnConfiguredHost, let url = URL(string: string) else {
            throw DownloadFailure.manifestInvalid("\(string) is not on a configured host")
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
            throw DownloadFailure.contentMismatched("The file \(file.path) did not match its hash")
        }
        return content.count
    }
}
