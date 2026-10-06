import Foundation

/// The SDK's directory in the app's private storage: content-addressed files and one manifest per bundle.
public final class FileStore {
    public enum Failure: Error, Equatable {
        case hashMismatch(expected: String, actual: String)
    }

    public let rootDirectory: URL
    private let fileManager = FileManager.default

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var filesDirectory: URL { rootDirectory.appendingPathComponent("files", isDirectory: true) }
    public var bundlesDirectory: URL { rootDirectory.appendingPathComponent("bundles", isDirectory: true) }

    public func fileURL(sha256: String) -> URL {
        return filesDirectory.appendingPathComponent(sha256)
    }

    public func hasFile(sha256: String) -> Bool {
        return fileManager.fileExists(atPath: fileURL(sha256: sha256).path)
    }

    /// Verifies the content against its hash, then writes it atomically; a file that exists is the file.
    public func writeFile(_ content: Data, sha256: String) throws {
        let actual = Hashing.sha256Hex(content)
        guard actual == sha256 else { throw Failure.hashMismatch(expected: sha256, actual: actual) }
        try createDirectory(filesDirectory)
        try content.write(to: fileURL(sha256: sha256), options: .atomic)
    }

    public func manifestURL(bundleId: String) -> URL {
        return bundlesDirectory.appendingPathComponent(bundleId, isDirectory: true).appendingPathComponent("manifest.json")
    }

    public func readManifest(bundleId: String) -> BundleManifest? {
        guard let data = try? Data(contentsOf: manifestURL(bundleId: bundleId)) else { return nil }
        return try? Json.decoder.decode(BundleManifest.self, from: data)
    }

    public func writeManifest(_ manifest: BundleManifest, bundleId: String) throws {
        let url = manifestURL(bundleId: bundleId)
        try createDirectory(url.deletingLastPathComponent())
        try Json.encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// Creates a directory inside the store; the store stays out of device backups, since everything in it downloads again.
    private func createDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try BackupExclusion.exclude(rootDirectory)
    }

    public func bundleIds() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: bundlesDirectory.path)) ?? []
        return contents.filter { readManifest(bundleId: $0) != nil }.sorted()
    }

    public func deleteBundle(bundleId: String) {
        try? fileManager.removeItem(at: bundlesDirectory.appendingPathComponent(bundleId, isDirectory: true))
    }

    /// Everything no kept bundle lists: the cleanup after a start, no setting.
    public func deleteUnusedFiles(keepingBundleIds kept: Set<String>) {
        for bundleId in bundleIds() where !kept.contains(bundleId) {
            deleteBundle(bundleId: bundleId)
        }
        let referenced = Set(kept.compactMap { readManifest(bundleId: $0) }.flatMap { $0.files.map { $0.sha256 } })
        let stored = (try? fileManager.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
        for sha256 in stored where !referenced.contains(sha256) {
            try? fileManager.removeItem(at: fileURL(sha256: sha256))
        }
    }

    public func deleteEverything() {
        try? fileManager.removeItem(at: rootDirectory)
    }

    /// The bytes free on the store's volume for a download the user expects, measured on its nearest existing directory; nil where the platform cannot tell.
    public func availableBytes() -> Int? {
        let directory = sequence(first: rootDirectory) { $0.deletingLastPathComponent() }.first { fileManager.fileExists(atPath: $0.path) }
        let values = try? directory?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    /// Whether every file the manifest lists is on disk; existence is the check, not a re-hash.
    public func isComplete(_ manifest: BundleManifest, embedded: EmbeddedBundle) -> Bool {
        return manifest.files.allSatisfy { hasFile(sha256: $0.sha256) || embedded.has(sha256: $0.sha256) }
    }
}

/// The files compiled into the binary, counted as present by hash; where they are is the platform's.
public protocol EmbeddedBundle {
    func has(sha256: String) -> Bool
    /// Copies the embedded file with that hash to the destination.
    func copyFile(sha256: String, to destination: URL) throws
}

/// Lays a bundle out by path for the WebView, linking to the content-addressed files where the platform allows.
public enum BundleProjection {
    public static func project(_ manifest: BundleManifest, from files: FileStore, embedded: EmbeddedBundle, into directory: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try BackupExclusion.exclude(directory)
        for file in manifest.files {
            let destination = directory.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.hasFile(sha256: file.sha256) {
                let source = files.fileURL(sha256: file.sha256)
                if (try? fileManager.linkItem(at: source, to: destination)) == nil {
                    try fileManager.copyItem(at: source, to: destination)
                }
            } else {
                try embedded.copyFile(sha256: file.sha256, to: destination)
            }
        }
    }
}

/// Keeps a directory and everything in it out of iCloud and computer backups and device-to-device transfers.
enum BackupExclusion {
    static func exclude(_ directory: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }
}
