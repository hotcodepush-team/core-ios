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
    /// The app's `rollback({ reason })` on `APP_REQUESTED`: printable, at most 256 characters.
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

    enum CodingKeys: String, CodingKey {
        case type, releaseId, bundleId, status, reason, condition, bytes, packKind, fromReleaseId, toReleaseId, detail
    }

    /// The keys the wire's schema names for the event's type, and no other: a required one is always written, as `null` where it is
    /// nullable and empty — a rollback to the embedded bundle carries `"toReleaseId": null` — and an optional one is left out when
    /// empty, since the schema refuses a `null` there.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch type {
        case "checked":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encodeIfPresent(condition, forKey: .condition)
        case "downloaded":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(bundleId, forKey: .bundleId)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(packKind, forKey: .packKind)
        case "failed":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(detail, forKey: .detail)
        case "rolledBack":
            try container.encode(fromReleaseId, forKey: .fromReleaseId)
            try container.encode(toReleaseId, forKey: .toReleaseId)
        default:
            try container.encode(releaseId, forKey: .releaseId)
        }
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

    enum CodingKeys: String, CodingKey {
        case attributes, binaryBuild, binaryVersion, channelId, channelSource, embeddedBundleId, fingerprint, osVersion, releaseId
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

/// What the events endpoint's answer means for a batch: taken, refused for good, or kept for the next sync.
enum BatchAnswer: Equatable {
    case acknowledged(reportedAt: Date)
    case refused(status: Int)
    /// No response, or one that asks for the batch again: `nil` when the endpoint could not be reached.
    case failed(status: Int?)

    /// A readable `202` takes the batch; a 4xx other than 408 and 429 refuses it for good; anything else asks for it again.
    init(_ response: HttpResponse?) {
        guard let response = response else {
            self = .failed(status: nil)
            return
        }
        switch response.status {
        case 202:
            if let acknowledged = try? Json.decoder.decode(DeviceEventsResponse.self, from: response.body) {
                self = .acknowledged(reportedAt: acknowledged.reportedAt)
            } else {
                self = .failed(status: response.status)
            }
        case 408, 429:
            self = .failed(status: response.status)
        case 400...499:
            self = .refused(status: response.status)
        default:
            self = .failed(status: response.status)
        }
    }
}
