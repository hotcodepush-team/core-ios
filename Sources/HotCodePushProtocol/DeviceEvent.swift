import Foundation

/// An outcome event or check event, queued in the outbox until the events endpoint acknowledges it.
public struct DeviceEvent: Codable, Equatable {
    public let type: String
    public let releaseId: String?
    public let bundleId: String?
    public let status: String?
    public let reason: String?
    public let condition: ConditionType?
    public let bytes: Int?
    public let packKind: String?
    public let fromReleaseId: String?
    public let toReleaseId: String?
    /// The app's `rollback({ reason })` on `REPORTED_BY_APP`: printable, at most 256 characters.
    public let detail: String?

    private init(type: String, releaseId: String? = nil, bundleId: String? = nil, status: String? = nil, reason: String? = nil, condition: ConditionType? = nil, bytes: Int? = nil, packKind: String? = nil, fromReleaseId: String? = nil, toReleaseId: String? = nil, detail: String? = nil) {
        self.type = type
        self.releaseId = releaseId
        self.bundleId = bundleId
        self.status = status
        self.reason = reason
        self.condition = condition
        self.bytes = bytes
        self.packKind = packKind
        self.fromReleaseId = fromReleaseId
        self.toReleaseId = toReleaseId
        self.detail = detail
    }

    public static func checked(releaseId: String, status: SyncStatus, reason: SkippedReason? = nil, condition: ConditionType? = nil) -> DeviceEvent {
        return DeviceEvent(type: "checked", releaseId: releaseId, status: status.rawValue, reason: reason?.rawValue, condition: condition)
    }

    public static func downloaded(releaseId: String, bundleId: String, bytes: Int, packKind: PackKind) -> DeviceEvent {
        return DeviceEvent(type: "downloaded", releaseId: releaseId, bundleId: bundleId, bytes: bytes, packKind: packKind.rawValue)
    }

    public static func applied(releaseId: String) -> DeviceEvent {
        return DeviceEvent(type: "applied", releaseId: releaseId)
    }

    public static func confirmed(releaseId: String) -> DeviceEvent {
        return DeviceEvent(type: "confirmed", releaseId: releaseId)
    }

    public static func failed(releaseId: String, reason: String, detail: String? = nil) -> DeviceEvent {
        return DeviceEvent(type: "failed", releaseId: releaseId, reason: reason, detail: detail)
    }

    public static func rolledBack(fromReleaseId: String, toReleaseId: String?) -> DeviceEvent {
        return DeviceEvent(type: "rolledBack", fromReleaseId: fromReleaseId, toReleaseId: toReleaseId)
    }
}

public enum PackKind: String, Codable {
    case full, delta, streamed, files
}

/// The facts the device reports, sent when they differ from the acknowledged ones or the month began.
public struct DeviceReport: Codable, Equatable {
    public let attributes: [String: String]
    public let binaryBuild: String
    public let binaryVersion: String
    public let channelId: String
    public let channelSource: ChannelSource
    public let embeddedBundleId: String?
    public let fingerprint: String?
    public let osVersion: String
    public let releaseId: String?
    /// The runtime version a bridge reports; this SDK has none.
    public let runtimeVersion: String?

    enum CodingKeys: String, CodingKey {
        case attributes, binaryBuild, binaryVersion, channelId, channelSource, embeddedBundleId, fingerprint, osVersion, releaseId, runtimeVersion
    }

    /// Every key on the wire, `null` for the empty ones, as the endpoint's schema asks.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(binaryBuild, forKey: .binaryBuild)
        try container.encode(binaryVersion, forKey: .binaryVersion)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(channelSource, forKey: .channelSource)
        try container.encode(embeddedBundleId, forKey: .embeddedBundleId)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(releaseId, forKey: .releaseId)
        try container.encode(runtimeVersion, forKey: .runtimeVersion)
    }
}

/// One batch to `POST /v1/apps/{appId}/events`: the outbox and, when it changed, the report.
public struct DeviceEventsRequest: Encodable {
    public let deviceId: String
    public let events: [DeviceEvent]
    public let platform: String
    public let report: DeviceReport?
    public let sdkVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceId, events, platform, report, sdkVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(events, forKey: .events)
        try container.encode(platform, forKey: .platform)
        try container.encode(report, forKey: .report)
        try container.encode(sdkVersion, forKey: .sdkVersion)
    }
}

/// The `202`: the server time the device stores as `reportedAt`.
public struct DeviceEventsResponse: Decodable {
    public let reportedAt: Date
}
