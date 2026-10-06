import Foundation

public enum ChannelChoice: Codable, Equatable {
    case id(String)
    case name(String)

    enum CodingKeys: String, CodingKey {
        case id, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self = .id(id)
        } else {
            self = .name(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let id): try container.encode(id, forKey: .id)
        case .name(let name): try container.encode(name, forKey: .name)
        }
    }
}

public struct CachedIndex: Codable, Equatable {
    public let etag: String?
    public let fetchedAt: Date
    public let body: ChannelIndex

    public init(etag: String?, fetchedAt: Date, body: ChannelIndex) {
        self.etag = etag
        self.fetchedAt = fetchedAt
        self.body = body
    }
}

public struct LastRollback: Codable, Equatable {
    public let from: Release
    public let to: Release?
    public let reason: RollbackReason

    public init(from: Release, to: Release?, reason: RollbackReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// The SDK's keys, `hotcodepush.<name>` each: three identity keys kept for the install's life,
/// the rest a cache under `stateVersion` that is dropped and rebuilt when unreadable.
public final class StateStore {
    public static let stateVersion = 2
    static let prefix = "hotcodepush."

    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
        if store.integer(forKey: StateStore.prefix + "stateVersion") != StateStore.stateVersion {
            deleteCacheKeys()
        }
    }

    // MARK: Identity

    public var deviceId: String {
        if let id = string("deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        set("deviceId", id)
        return id
    }

    public var attributes: [String: String] {
        get { return read("attributes") ?? [:] }
        set { write("attributes", newValue) }
    }

    public var channel: ChannelChoice? {
        get { return read("channel") }
        set { write("channel", newValue) }
    }

    // MARK: Cache

    public var currentRelease: Release? {
        get { return read("currentRelease") }
        set { write("currentRelease", newValue) }
    }

    public var nextRelease: Release? {
        get { return read("nextRelease") }
        set { write("nextRelease", newValue) }
    }

    public var fallbackRelease: Release? {
        get { return read("fallbackRelease") }
        set { write("fallbackRelease", newValue) }
    }

    public var failedBundleIds: [String] {
        get { return read("failedBundleIds") ?? [] }
        set { write("failedBundleIds", newValue) }
    }

    /// The floor of the binary that last started, to notice a new one.
    public var lastBuiltAt: Date? {
        get { return string("lastBuiltAt").flatMap(Iso8601.parse) }
        set { set("lastBuiltAt", newValue.map(Iso8601.format)) }
    }

    public var reportedAt: Date? {
        get { return string("reportedAt").flatMap(Iso8601.parse) }
        set { set("reportedAt", newValue.map(Iso8601.format)) }
    }

    public var acknowledgedReport: DeviceReport? {
        get { return read("acknowledgedReport") }
        set { write("acknowledgedReport", newValue) }
    }

    public var lastCheck: LastCheck? {
        get { return read("lastCheck") }
        set { write("lastCheck", newValue) }
    }

    public var cachedIndex: CachedIndex? {
        get { return read("cachedIndex") }
        set { write("cachedIndex", newValue) }
    }

    public var unsentEvents: [DeviceEvent] {
        get { return read("unsentEvents") ?? [] }
        set { write("unsentEvents", newValue) }
    }

    public var checkedReleaseIds: [String] {
        get { return read("checkedReleaseIds") ?? [] }
        set { write("checkedReleaseIds", newValue) }
    }

    public var lastRollback: LastRollback? {
        get { return read("lastRollback") }
        set { write("lastRollback", newValue) }
    }

    public var lastSyncAt: Date? {
        get { return string("lastSyncAt").flatMap(Iso8601.parse) }
        set { set("lastSyncAt", newValue.map(Iso8601.format)) }
    }

    /// Drops every cache key; the identity keys survive. Called at start on an unknown version, never by the app.
    public func deleteCacheKeys() {
        for key in ["currentRelease", "nextRelease", "fallbackRelease", "failedBundleIds", "lastBuiltAt", "reportedAt", "acknowledgedReport", "lastCheck", "cachedIndex", "unsentEvents", "checkedReleaseIds", "lastRollback", "lastSyncAt"] {
            set(key, nil)
        }
        store.set(StateStore.stateVersion, forKey: StateStore.prefix + "stateVersion")
    }

    // MARK: Plumbing

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let raw = string(key) else { return nil }
        do {
            return try Json.decoder.decode(T.self, from: Data(raw.utf8))
        } catch {
            deleteCacheKeys()
            return nil
        }
    }

    private func write<T: Encodable>(_ key: String, _ value: T?) {
        guard let value = value, let data = try? Json.encoder.encode(value) else {
            set(key, nil)
            return
        }
        set(key, String(bytes: data, encoding: .utf8))
    }

    private func string(_ key: String) -> String? {
        return store.string(forKey: StateStore.prefix + key)
    }

    private func set(_ key: String, _ value: String?) {
        store.set(value, forKey: StateStore.prefix + key)
    }
}
