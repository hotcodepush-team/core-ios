import Foundation

/// The channel's index for a platform: `/apps/{appId}/channels/{channelId}/{platform}/v1/index.json`.
public struct ChannelIndex: Codable, Equatable {
    public static let schema = 1
    public static let platforms = ["android", "ios"]

    public let schema: Int
    public let sequence: Int
    public let appId: String
    public let channelId: String
    public let platform: String
    public let isPaused: Bool
    public let cappedAt: Date?
    public let revokedReleaseIds: [String]
    public let releases: [IndexRelease]

    enum CodingKeys: String, CodingKey {
        case schema, sequence, appId, channelId, platform, isPaused, cappedAt, revokedReleaseIds, releases
    }

    public init(schema: Int = ChannelIndex.schema, sequence: Int, appId: String, channelId: String, platform: String, isPaused: Bool = false, cappedAt: Date? = nil, revokedReleaseIds: [String] = [], releases: [IndexRelease]) {
        self.schema = schema
        self.sequence = sequence
        self.appId = appId
        self.channelId = channelId
        self.platform = platform
        self.isPaused = isPaused
        self.cappedAt = cappedAt
        self.revokedReleaseIds = revokedReleaseIds
        self.releases = releases
    }

    /// Every field of the format is present, a nullable one as `null`; another schema major or platform fails the whole index.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        guard schema == ChannelIndex.schema else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "The index has schema \(schema), this reader reads \(ChannelIndex.schema)")
        }
        sequence = try container.decodeInt(forKey: .sequence, minimum: 0)
        appId = try container.decode(.nonEmpty, forKey: .appId)
        channelId = try container.decode(.nonEmpty, forKey: .channelId)
        platform = try container.decode(String.self, forKey: .platform)
        guard ChannelIndex.platforms.contains(platform) else {
            throw DecodingError.dataCorruptedError(forKey: .platform, in: container, debugDescription: "Not a platform: \(platform)")
        }
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        cappedAt = try container.decodeNullable(Date.self, forKey: .cappedAt)
        revokedReleaseIds = try container.decode([String].self, forKey: .revokedReleaseIds)
        for id in revokedReleaseIds where !WireRule.identifier.accepts(id) {
            throw DecodingError.dataCorruptedError(forKey: .revokedReleaseIds, in: container, debugDescription: "Not a valid release id: \(id)")
        }
        releases = try container.decode([IndexRelease].self, forKey: .releases)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(appId, forKey: .appId)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(platform, forKey: .platform)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(cappedAt, forKey: .cappedAt)
        try container.encode(revokedReleaseIds, forKey: .revokedReleaseIds)
        try container.encode(releases, forKey: .releases)
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

    enum CodingKeys: String, CodingKey {
        case id, number, createdAt, isMandatory, notes, rollout, conditions, bundleId, bundleVersion, manifestUrl, manifestSha256, sizeBytes
    }

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
        number = try container.decodeInt(forKey: .number, minimum: 1)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isMandatory = try container.decode(Bool.self, forKey: .isMandatory)
        notes = try container.decodeNullable(String.self, forKey: .notes)
        rollout = try container.decodeInt(forKey: .rollout, minimum: 0, maximum: 100)
        conditions = try container.decode([Condition].self, forKey: .conditions)
        bundleId = try container.decode(.identifier, forKey: .bundleId)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        manifestUrl = try container.decode(.url, forKey: .manifestUrl)
        manifestSha256 = try container.decode(.sha256, forKey: .manifestSha256)
        sizeBytes = try container.decodeInt(forKey: .sizeBytes, minimum: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(number, forKey: .number)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isMandatory, forKey: .isMandatory)
        try container.encode(notes, forKey: .notes)
        try container.encode(rollout, forKey: .rollout)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(bundleVersion, forKey: .bundleVersion)
        try container.encode(manifestUrl, forKey: .manifestUrl)
        try container.encode(manifestSha256, forKey: .manifestSha256)
        try container.encode(sizeBytes, forKey: .sizeBytes)
    }

    public var release: Release {
        return Release(id: id, number: number, bundleId: bundleId, bundleVersion: bundleVersion, isMandatory: isMandatory)
    }
}

public enum ConditionType: String, Codable {
    case binary, fingerprint, os, attribute, device
}

/// A condition of an index entry; a type this SDK does not know is kept and fails closed.
public enum Condition: Codable, Equatable {
    case binary(range: String)
    case fingerprint(hash: String)
    case os(range: String)
    case device(hashedIds: [String])
    case attribute(key: String, valueSha256: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, range, hash, hashedIds, key, valueSha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "binary": self = .binary(range: try container.decode(.nonEmpty, forKey: .range))
        case "fingerprint": self = .fingerprint(hash: try container.decode(.nonEmpty, forKey: .hash))
        case "os": self = .os(range: try container.decode(.nonEmpty, forKey: .range))
        case "device": self = .device(hashedIds: try container.decode([String].self, forKey: .hashedIds))
        case "attribute": self = .attribute(key: try container.decode(.nonEmpty, forKey: .key), valueSha256: try container.decode(.sha256, forKey: .valueSha256))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .binary(let range):
            try container.encode("binary", forKey: .type)
            try container.encode(range, forKey: .range)
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

    enum CodingKeys: String, CodingKey {
        case schema, channels
    }

    public init(schema: Int = ChannelIndex.schema, channels: [Entry]) {
        self.schema = schema
        self.channels = channels
    }

    /// Another schema major fails the whole index, as the channel's index does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        guard schema == ChannelIndex.schema else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "The channels index has schema \(schema), this reader reads \(ChannelIndex.schema)")
        }
        channels = try container.decode([Entry].self, forKey: .channels)
    }
}

/// A signature as the envelope carries it: the signing key's fingerprint and the self-describing `<scheme>:<base64>` value.
public struct Signature: Codable, Equatable {
    public let keyId: String
    public let value: String

    enum CodingKeys: String, CodingKey {
        case keyId, value
    }

    public init(keyId: String, value: String) {
        self.keyId = keyId
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decode(.nonEmpty, forKey: .keyId)
        value = try container.decode(.signatureValue, forKey: .value)
    }
}

/// The document at `/apps/{appId}/bundles/{bundleId}/manifest.json`: the manifest as the signed string, its signature, the
/// reserved encryption slot and, unsigned beside them, the server's facts — the bundle's id and creation time, and the pack
/// and the deltas as stored. An envelope stored while bundles carried `patches` still parses; the key is not read.
public struct ManifestEnvelope: Codable, Equatable {
    public struct Pack: Codable, Equatable {
        public let url: String
        public let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case url, sizeBytes
        }

        public init(url: String, sizeBytes: Int) {
            self.url = url
            self.sizeBytes = sizeBytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(.url, forKey: .url)
            sizeBytes = try container.decodeInt(forKey: .sizeBytes, minimum: 0)
        }
    }

    public struct Delta: Codable, Equatable {
        public let baseBundleId: String
        public let url: String
        public let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case baseBundleId, url, sizeBytes
        }

        public init(baseBundleId: String, url: String, sizeBytes: Int) {
            self.baseBundleId = baseBundleId
            self.url = url
            self.sizeBytes = sizeBytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseBundleId = try container.decode(.identifier, forKey: .baseBundleId)
            url = try container.decode(.url, forKey: .url)
            sizeBytes = try container.decodeInt(forKey: .sizeBytes, minimum: 0)
        }
    }

    public let bundleId: String
    public let createdAt: Date
    public let manifest: String
    public let signature: Signature?
    public let pack: Pack
    public let deltas: [Delta]

    enum CodingKeys: String, CodingKey {
        case bundleId, createdAt, manifest, signature, encryption, pack, deltas
    }

    public init(bundleId: String, createdAt: Date, manifest: String, signature: Signature? = nil, pack: Pack, deltas: [Delta] = []) {
        self.bundleId = bundleId
        self.createdAt = createdAt
        self.manifest = manifest
        self.signature = signature
        self.pack = pack
        self.deltas = deltas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decode(.identifier, forKey: .bundleId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        manifest = try container.decode(.nonEmpty, forKey: .manifest)
        signature = try container.decodeNullable(Signature.self, forKey: .signature)
        guard container.contains(.encryption), try container.decodeNil(forKey: .encryption) else {
            throw DecodingError.dataCorruptedError(forKey: .encryption, in: container, debugDescription: "The encryption slot is reserved and null")
        }
        pack = try container.decode(Pack.self, forKey: .pack)
        deltas = try container.decode([Delta].self, forKey: .deltas)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(signature, forKey: .signature)
        try container.encodeNil(forKey: .encryption)
        try container.encode(pack, forKey: .pack)
        try container.encode(deltas, forKey: .deltas)
    }

    public func decodeManifest() throws -> BundleManifest {
        return try Json.decoder.decode(BundleManifest.self, from: Data(manifest.utf8))
    }
}

/// The bundle manifest, the content the CLI knows before the upload and signs as canonical JSON: the files with their hashes
/// and sizes, the platforms, the bundle version, the fingerprint and the signing key's id. A manifest stored while bundles
/// carried `patches` still parses; the key is not read.
public struct BundleManifest: Codable, Equatable {
    public struct File: Codable, Equatable {
        public let path: String
        public let sha256: String
        public let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case path, sha256, sizeBytes
        }

        public init(path: String, sha256: String, sizeBytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(.relativePath, forKey: .path)
            sha256 = try container.decode(.sha256, forKey: .sha256)
            sizeBytes = try container.decodeInt(forKey: .sizeBytes, minimum: 0)
        }
    }

    public let appId: String
    public let bundleVersion: String
    public let files: [File]
    public let fingerprint: String?
    /// The fingerprint of the key that signed the manifest, `nil` when unsigned.
    public let keyId: String?
    public let platforms: [String]

    enum CodingKeys: String, CodingKey {
        case appId, bundleVersion, files, fingerprint, keyId, platforms
    }

    public init(appId: String, bundleVersion: String, files: [File], fingerprint: String? = nil, keyId: String? = nil, platforms: [String]) {
        self.appId = appId
        self.bundleVersion = bundleVersion
        self.files = files
        self.fingerprint = fingerprint
        self.keyId = keyId
        self.platforms = platforms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(.nonEmpty, forKey: .appId)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        files = try container.decode([File].self, forKey: .files)
        fingerprint = try container.decodeNullable(.nonEmpty, forKey: .fingerprint)
        keyId = try container.decodeNullable(.nonEmpty, forKey: .keyId)
        platforms = try container.decodePlatforms(forKey: .platforms)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appId, forKey: .appId)
        try container.encode(bundleVersion, forKey: .bundleVersion)
        try container.encode(files, forKey: .files)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(platforms, forKey: .platforms)
    }

    public func sha256(forPath path: String) -> String? {
        return files.first { $0.path == path }?.sha256
    }

    /// Whether the manifest names the device's app and lists its platform, signed or not: neither an index pointing at another
    /// app's bundle nor a cache serving one installs it.
    public func isForDevice(appId: String, platform: String) -> Bool {
        return self.appId == appId && platforms.contains(platform)
    }
}

/// The embedded bundle's manifest in the resource file, the bundle manifest itself.
public typealias EmbeddedBundleManifest = BundleManifest

/// What a value may hold before it names a file, a directory or a host: nothing that climbs out of its directory, nothing off the wire's format.
enum WireRule {
    /// Letters, digits, `_` and `-`, at most 64: a bundle id names a directory.
    case identifier
    /// 64 lowercase hexadecimal characters: a file hash names a file.
    case sha256
    /// A UUID in its canonical spelling, lowercase hexadecimal in groups of 8, 4, 4, 4 and 12: a channel id names a path on the files host.
    case uuid
    /// Relative and `/`-separated, with no empty, `.` or `..` segment, no backslash and no NUL.
    case relativePath
    /// At least one character.
    case nonEmpty
    /// An absolute `http` or `https` URL with a host: `javascript:`, `file:`, `data:` and every other scheme are refused.
    case url
    /// The scheme, a colon and the base64 of the signature.
    case signatureValue

    private static let urlSchemes: Set = ["http", "https"]
    private static let identifierScalars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".unicodeScalars)
    private static let sha256Scalars = Set("0123456789abcdef".unicodeScalars)
    private static let schemeScalars = Set("abcdefghijklmnopqrstuvwxyz0123456789_-".unicodeScalars)
    private static let base64Scalars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".unicodeScalars)

    func accepts(_ value: String) -> Bool {
        switch self {
        case .identifier:
            return (1...64).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(WireRule.identifierScalars.contains)
        case .sha256:
            return value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy(WireRule.sha256Scalars.contains)
        case .uuid:
            let groups = value.unicodeScalars.split(separator: "-", omittingEmptySubsequences: false)
            return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(WireRule.sha256Scalars.contains) }
        case .relativePath:
            return WireRule.isRelativePath(value)
        case .nonEmpty:
            return !value.isEmpty
        case .url:
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
            return WireRule.urlSchemes.contains(scheme) && !host.isEmpty
        case .signatureValue:
            return WireRule.isSignatureValue(value)
        }
    }

    /// Unicode's `Cc`: the C0 controls, DEL and the C1 controls.
    static func isControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.properties.generalCategory == .control
    }

    /// The segments are split on the `/` scalar, never on characters: a slash followed by a combining mark is still a separator, so `..` cannot hide behind one.
    private static func isRelativePath(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.contains("\\"), !scalars.contains("\0") else { return false }
        return scalars.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            let segmentScalars = Array(segment)
            return !segmentScalars.isEmpty && segmentScalars != ["."] && segmentScalars != [".", "."]
        }
    }

    private static func isSignatureValue(_ value: String) -> Bool {
        let parts = value.unicodeScalars.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let scheme = Array(parts[0])
        let payload = Array(parts[1])
        guard !scheme.isEmpty, scheme.allSatisfy(WireRule.schemeScalars.contains) else { return false }
        let padding = payload.reversed().prefix { $0 == "=" }.count
        let body = payload.dropLast(padding)
        return !body.isEmpty && body.allSatisfy(WireRule.base64Scalars.contains)
    }
}

extension KeyedDecodingContainer {
    /// A string the rule accepts; anything else fails the decode before it can name a file, a directory or a host.
    func decode(_ rule: WireRule, forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard rule.accepts(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a valid \(key.stringValue): \(value)")
        }
        return value
    }

    /// An optional string the rule accepts when it is there.
    func decodeIfPresent(_ rule: WireRule, forKey key: Key) throws -> String? {
        guard contains(key) else { return nil }
        return try decode(rule, forKey: key)
    }

    /// A key that must be present, `null` when it holds nothing: the wire carries every field, so an absent one is a broken document, never an empty value.
    func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: codingPath, debugDescription: "\(key.stringValue) is absent; the wire carries it as null when there is none"))
        }
        return try decodeIfPresent(type, forKey: key)
    }

    func decodeNullable(_ rule: WireRule, forKey key: Key) throws -> String? {
        guard let value = try decodeNullable(String.self, forKey: key) else { return nil }
        guard rule.accepts(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a valid \(key.stringValue): \(value)")
        }
        return value
    }

    /// An integer within its bounds; a fraction, a string or a number outside them fails the decode.
    func decodeInt(forKey key: Key, minimum: Int, maximum: Int = Int.max) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        guard (minimum...maximum).contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(key.stringValue) is out of bounds: \(value)")
        }
        return value
    }

    /// The platforms a bundle serves, each a non-empty name; a reader keeps a platform it does not know.
    func decodePlatforms(forKey key: Key) throws -> [String] {
        let platforms = try decode([String].self, forKey: key)
        guard platforms.allSatisfy({ !$0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "A platform is empty")
        }
        return platforms
    }
}
