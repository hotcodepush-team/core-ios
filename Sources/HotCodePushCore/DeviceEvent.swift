import Foundation

/// An outcome event or check event, queued in the outbox until the events endpoint acknowledges it.
public struct DeviceEvent: Codable, Equatable {
    public let type: String
    public let releaseId: String?
    public let status: String?
    public let reason: String?
    public let conditionType: ConditionType?
    public let downloadSizeBytes: Int?
    public let packKind: String?
    /// The app's `rollback({ reason })` on `app_requested`: printable, at most 256 characters.
    public let detail: String?

    private init(type: String, releaseId: String? = nil, status: String? = nil, reason: String? = nil, conditionType: ConditionType? = nil, downloadSizeBytes: Int? = nil, packKind: String? = nil, detail: String? = nil) {
        self.type = type
        self.releaseId = releaseId
        self.status = status
        self.reason = reason
        self.conditionType = conditionType
        self.downloadSizeBytes = downloadSizeBytes
        self.packKind = packKind
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case type, releaseId, status, reason, conditionType, downloadSizeBytes, packKind, detail
    }

    /// Writes only the keys the schema names for the event type.
    /// A required key is always written, as `null` when empty; an optional one is left out when empty, since the schema refuses a `null` there.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch type {
        case "checked":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encodeIfPresent(conditionType, forKey: .conditionType)
        case "downloaded":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(downloadSizeBytes, forKey: .downloadSizeBytes)
            try container.encode(packKind, forKey: .packKind)
        case "failed":
            try container.encode(releaseId, forKey: .releaseId)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(detail, forKey: .detail)
        default:
            try container.encode(releaseId, forKey: .releaseId)
        }
    }

    public static func checked(releaseId: String, status: SyncStatus, reason: SkippedReason? = nil, conditionType: ConditionType? = nil) -> DeviceEvent {
        return DeviceEvent(type: "checked", releaseId: releaseId, status: status.rawValue, reason: reason?.rawValue, conditionType: conditionType)
    }

    public static func downloaded(releaseId: String, downloadSizeBytes: Int, packKind: PackKind) -> DeviceEvent {
        return DeviceEvent(type: "downloaded", releaseId: releaseId, downloadSizeBytes: downloadSizeBytes, packKind: packKind.rawValue)
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
}

public enum PackKind: String, CaseIterable, Codable {
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

    /// Writes every key, `null` for an empty one, as the endpoint schema asks.
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

    // A refused report would cost the events of every batch, so the device never sends one.
    var isReadable: Bool {
        let texts = [binaryBuild, binaryVersion, channelId, osVersion] + [fingerprint].compactMap { $0 }
        let ids = [embeddedBundleId, releaseId].compactMap { $0 }
        return texts.allSatisfy(WireRule.printable.accepts) && ids.allSatisfy(WireRule.identifier.accepts)
            && attributes.allSatisfy { AttributeRules.isValid(key: $0.key) && AttributeRules.isValid(value: $0.value) }
    }
}

/// One batch to `POST /v1/apps/{appId}/events`: the outbox and, when it changed, the report.
public struct DeviceEventsRequest: Encodable {
    // The events endpoint refuses a larger batch, so this also caps the outbox.
    static let maximumEventCount = 200

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

    var isReadable: Bool {
        return WireRule.uuid.accepts(deviceId) && WireRule.printable.accepts(sdkVersion) && ChannelIndex.platforms.contains(platform)
            && events.count <= DeviceEventsRequest.maximumEventCount && (report?.isReadable ?? true)
    }
}

/// The body of a `202` from the events endpoint: the server time the device may keep as `reportedAt`.
public struct DeviceEventsResponse: Decodable {
    public let reportedAt: Date
}

struct DeviceEventsAcknowledgement: Equatable {
    let hasReport: Bool
    let reportedAt: Date

    // Only a batch that carried the report moves the stamp, and only into a later UTC month.
    // So the device compares with `cappedAt` the same stamp the consumer counted it by.
    func resolveKeptReportedAt(held heldReportedAt: Date?) -> Date? {
        guard hasReport else { return heldReportedAt }
        guard let heldReportedAt = heldReportedAt else { return reportedAt }
        return Iso8601.resolveUtcMonth(of: reportedAt) > Iso8601.resolveUtcMonth(of: heldReportedAt) ? reportedAt : heldReportedAt
    }
}

enum BatchAnswer: Equatable {
    case acknowledged(reportedAt: Date)
    case refused(status: Int)
    // The status is `nil` when the endpoint could not be reached.
    case failed(status: Int?)

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
