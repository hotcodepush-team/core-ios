import Foundation

/// The channel's index for a platform: `/apps/{appId}/channels/{channelId}/{platform}/v1/index.json`.
public struct ChannelIndex: Codable, Equatable {
    public static let schema = 1

    public let schema: Int
    public let sequence: Int
    public let appId: String
    public let channelId: String
    public let platform: String
    public let isPaused: Bool
    public let cappedAt: Date?
    public let revokedReleaseIds: [String]
    public let rollBackToEmbedded: RollBackToEmbedded?
    public let releases: [IndexRelease]

    public init(schema: Int = ChannelIndex.schema, sequence: Int, appId: String, channelId: String, platform: String, isPaused: Bool = false, cappedAt: Date? = nil, revokedReleaseIds: [String] = [], rollBackToEmbedded: RollBackToEmbedded? = nil, releases: [IndexRelease]) {
        self.schema = schema
        self.sequence = sequence
        self.appId = appId
        self.channelId = channelId
        self.platform = platform
        self.isPaused = isPaused
        self.cappedAt = cappedAt
        self.revokedReleaseIds = revokedReleaseIds
        self.rollBackToEmbedded = rollBackToEmbedded
        self.releases = releases
    }
}

public struct RollBackToEmbedded: Codable, Equatable {
    public let aboveNumber: Int
    public let signature: Signature?

    public init(aboveNumber: Int, signature: Signature? = nil) {
        self.aboveNumber = aboveNumber
        self.signature = signature
    }
}

public struct IndexRelease: Codable, Equatable {
    public let id: String
    public let number: Int
    public let createdAt: Date
    public let isMandatory: Bool
    public let notes: String?
    public let rollout: Int
    public let conditions: [Condition]
    public let bundleId: String
    public let bundleVersion: String
    public let manifestUrl: String
    public let manifestSha256: String
    public let sizeBytes: Int

    public init(id: String, number: Int, createdAt: Date, isMandatory: Bool = false, notes: String? = nil, rollout: Int = 100, conditions: [Condition] = [], bundleId: String, bundleVersion: String, manifestUrl: String, manifestSha256: String, sizeBytes: Int) {
        self.id = id
        self.number = number
        self.createdAt = createdAt
        self.isMandatory = isMandatory
        self.notes = notes
        self.rollout = rollout
        self.conditions = conditions
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion
        self.manifestUrl = manifestUrl
        self.manifestSha256 = manifestSha256
        self.sizeBytes = sizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(.identifier, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isMandatory = try container.decode(Bool.self, forKey: .isMandatory)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        rollout = try container.decode(Int.self, forKey: .rollout)
        conditions = try container.decode([Condition].self, forKey: .conditions)
        bundleId = try container.decode(.identifier, forKey: .bundleId)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        manifestUrl = try container.decode(String.self, forKey: .manifestUrl)
        manifestSha256 = try container.decode(.sha256, forKey: .manifestSha256)
        sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
    }

    public var release: Release {
        return Release(id: id, number: number, bundleId: bundleId, bundleVersion: bundleVersion, isMandatory: isMandatory)
    }
}

public enum ConditionType: String, Codable {
    case binary, runtime, fingerprint, os, attribute, device
}

/// A condition of an index entry; a type this SDK does not know is kept and fails closed.
public enum Condition: Codable, Equatable {
    case binary(range: String)
    case runtime(version: String)
    case fingerprint(hash: String)
    case os(range: String)
    case device(hashedIds: [String])
    case attribute(key: String, valueSha256: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, range, version, hash, hashedIds, key, valueSha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "binary": self = .binary(range: try container.decode(String.self, forKey: .range))
        case "runtime": self = .runtime(version: try container.decode(String.self, forKey: .version))
        case "fingerprint": self = .fingerprint(hash: try container.decode(String.self, forKey: .hash))
        case "os": self = .os(range: try container.decode(String.self, forKey: .range))
        case "device": self = .device(hashedIds: try container.decode([String].self, forKey: .hashedIds))
        case "attribute": self = .attribute(key: try container.decode(String.self, forKey: .key), valueSha256: try container.decode(String.self, forKey: .valueSha256))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .binary(let range):
            try container.encode("binary", forKey: .type)
            try container.encode(range, forKey: .range)
        case .runtime(let version):
            try container.encode("runtime", forKey: .type)
            try container.encode(version, forKey: .version)
        case .fingerprint(let hash):
            try container.encode("fingerprint", forKey: .type)
            try container.encode(hash, forKey: .hash)
        case .os(let range):
            try container.encode("os", forKey: .type)
            try container.encode(range, forKey: .range)
        case .device(let hashedIds):
            try container.encode("device", forKey: .type)
            try container.encode(hashedIds, forKey: .hashedIds)
        case .attribute(let key, let valueSha256):
            try container.encode("attribute", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(valueSha256, forKey: .valueSha256)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }

    public var type: ConditionType? {
        switch self {
        case .binary: return .binary
        case .runtime: return .runtime
        case .fingerprint: return .fingerprint
        case .os: return .os
        case .device: return .device
        case .attribute: return .attribute
        case .unknown: return nil
        }
    }
}

/// The discoverable channels of the app, for switching by name at runtime.
public struct ChannelsIndex: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public let schema: Int
    public let channels: [Entry]

    public init(schema: Int = ChannelIndex.schema, channels: [Entry]) {
        self.schema = schema
        self.channels = channels
    }
}

public struct Signature: Codable, Equatable {
    public let keyId: String
    public let value: String

    public init(keyId: String, value: String) {
        self.keyId = keyId
        self.value = value
    }
}

/// The envelope at `/apps/{appId}/bundles/{bundleId}/manifest.json`; the signature covers the `manifest` bytes.
public struct ManifestEnvelope: Codable, Equatable {
    public let manifest: String
    public let signature: Signature?

    public init(manifest: String, signature: Signature? = nil) {
        self.manifest = manifest
        self.signature = signature
    }

    public func decodeManifest() throws -> BundleManifest {
        return try Json.decoder.decode(BundleManifest.self, from: Data(manifest.utf8))
    }
}

public struct BundleManifest: Codable, Equatable {
    public struct File: Codable, Equatable {
        public let path: String
        public let sha256: String
        public let sizeBytes: Int

        public init(path: String, sha256: String, sizeBytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(.relativePath, forKey: .path)
            sha256 = try container.decode(.sha256, forKey: .sha256)
            sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        }
    }

    public struct Pack: Codable, Equatable {
        public let url: String
        public let sizeBytes: Int

        public init(url: String, sizeBytes: Int) {
            self.url = url
            self.sizeBytes = sizeBytes
        }
    }

    public struct Delta: Codable, Equatable {
        public let baseBundleId: String
        public let url: String
        public let sizeBytes: Int

        public init(baseBundleId: String, url: String, sizeBytes: Int) {
            self.baseBundleId = baseBundleId
            self.url = url
            self.sizeBytes = sizeBytes
        }
    }

    public let bundleId: String
    public let appId: String
    public let version: String
    public let createdAt: Date
    public let files: [File]
    public let pack: Pack?
    public let deltas: [Delta]

    enum CodingKeys: String, CodingKey {
        case bundleId, appId, version, createdAt, files, pack, deltas
    }

    public init(bundleId: String, appId: String, version: String, createdAt: Date, files: [File], pack: Pack? = nil, deltas: [Delta] = []) {
        self.bundleId = bundleId
        self.appId = appId
        self.version = version
        self.createdAt = createdAt
        self.files = files
        self.pack = pack
        self.deltas = deltas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decode(.identifier, forKey: .bundleId)
        appId = try container.decode(String.self, forKey: .appId)
        version = try container.decode(String.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        files = try container.decode([File].self, forKey: .files)
        pack = try container.decodeIfPresent(Pack.self, forKey: .pack)
        deltas = try container.decodeIfPresent([Delta].self, forKey: .deltas) ?? []
    }

    public func sha256(forPath path: String) -> String? {
        return files.first { $0.path == path }?.sha256
    }
}

/// What a value may hold before it names a file or a directory: nothing that climbs out of its directory.
enum WireRule {
    /// Letters, digits, `_` and `-`, at most 64: a bundle id names a directory.
    case identifier
    /// 64 lowercase hexadecimal characters: a file hash names a file.
    case sha256
    /// Relative and `/`-separated, with no empty, `.` or `..` segment, no backslash and no NUL.
    case relativePath

    private static let identifierBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
    private static let sha256Bytes = Set("0123456789abcdef".utf8)

    func accepts(_ value: String) -> Bool {
        switch self {
        case .identifier:
            return (1...64).contains(value.utf8.count) && value.utf8.allSatisfy(WireRule.identifierBytes.contains)
        case .sha256:
            return value.utf8.count == 64 && value.utf8.allSatisfy(WireRule.sha256Bytes.contains)
        case .relativePath:
            return !value.contains("\\") && !value.contains("\0") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
    }
}

extension KeyedDecodingContainer {
    /// A string the rule accepts; anything else fails the decode before it can name a file or a directory.
    func decode(_ rule: WireRule, forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard rule.accepts(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a valid \(key.stringValue): \(value)")
        }
        return value
    }
}
