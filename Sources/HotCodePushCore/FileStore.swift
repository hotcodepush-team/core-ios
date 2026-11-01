import Foundation

/// The SDK's directory in the app's private storage: content-addressed files and one manifest per bundle.
public final class FileStore {
    public enum Failure: Error, Equatable {
        case hashMismatch(expected: String, actual: String)
    }

    /// `hotcodepush` in Application Support, where every SDK keeps its store; its loader may lay bundles out there too.
    public static let defaultRootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("hotcodepush", isDirectory: true)

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

    /// Verifies the file at `source` against its hash in chunks, then moves it into the store.
    /// A file that exists already is kept, and the source is removed.
    public func writeFile(at source: URL, sha256: String) throws {
        let actual = try Hashing.sha256Hex(fileAt: source)
        guard actual == sha256 else { throw Failure.hashMismatch(expected: sha256, actual: actual) }
        try createDirectory(filesDirectory)
        let destination = fileURL(sha256: sha256)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
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

    // The store stays out of device backups, since everything in it downloads again.
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

    /// Deletes every stored file no kept bundle lists.
    /// Delete the other bundles first, through `deleteBundle(bundleId:)`.
    public func deleteUnusedFiles(keepingBundleIds kept: Set<String>) {
        let referenced = Set(kept.compactMap { readManifest(bundleId: $0) }.flatMap { $0.files.map { $0.sha256 } })
        let stored = (try? fileManager.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
        for sha256 in stored where !referenced.contains(sha256) {
            try? fileManager.removeItem(at: fileURL(sha256: sha256))
        }
    }

    public func deleteEverything() {
        try? fileManager.removeItem(at: rootDirectory)
    }

    /// The bytes free on the volume of the store, `nil` where the platform cannot tell.
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

/// The files compiled into the binary, addressed by the hashes of the embedded manifest; none in a build without a manifest.
public final class AppBundleEmbeddedBundle: EmbeddedBundle {
    private let pathsBySha256: [String: String]
    private let rootDirectory: URL

    public init(manifest: EmbeddedBundleManifest?, rootDirectory: URL) {
        var paths: [String: String] = [:]
        for file in manifest?.files ?? [] {
            paths[file.sha256] = file.path
        }
        pathsBySha256 = paths
        self.rootDirectory = rootDirectory
    }

    public func has(sha256: String) -> Bool {
        guard let path = pathsBySha256[sha256] else { return false }
        return FileManager.default.fileExists(atPath: fileURL(path: path).path)
    }

    public func copyFile(sha256: String, to destination: URL) throws {
        guard let path = pathsBySha256[sha256] else { throw PlainError("No embedded file with hash \(sha256)") }
        try FileManager.default.copyItem(at: fileURL(path: path), to: destination)
    }

    private func fileURL(path: String) -> URL {
        return rootDirectory.appendingPathComponent(path)
    }
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

enum BackupExclusion {
    static func exclude(_ directory: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }
}
