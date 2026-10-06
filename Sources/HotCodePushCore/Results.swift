import Foundation

public enum SyncTrigger: String, Codable {
    case start, resume, interval, manual
}

public enum SyncStatus: String, Codable {
    case upToDate = "UP_TO_DATE"
    case available = "AVAILABLE"
    case downloaded = "DOWNLOADED"
    case updated = "UPDATED"
    case skipped = "SKIPPED"
    case failed = "FAILED"
}

public enum SkippedReason: String, Codable {
    case incompatible = "INCOMPATIBLE"
    case notTargeted = "NOT_TARGETED"
    case notInRollout = "NOT_IN_ROLLOUT"
    case unsupportedCondition = "UNSUPPORTED_CONDITION"
    case olderThanBinary = "OLDER_THAN_BINARY"
    case channelPaused = "CHANNEL_PAUSED"
    case spendingCapReached = "SPENDING_CAP_REACHED"
    case releaseRevoked = "RELEASE_REVOKED"
    case failedBefore = "FAILED_BEFORE"
    case debugBuild = "DEBUG_BUILD"
    case meteredConnection = "METERED_CONNECTION"
}

public enum FailedReason: String, Codable {
    case offline = "OFFLINE"
    case unknownChannel = "UNKNOWN_CHANNEL"
    case invalidIndex = "INVALID_INDEX"
    case invalidSignature = "INVALID_SIGNATURE"
    case downloadFailed = "DOWNLOAD_FAILED"
    case verificationFailed = "VERIFICATION_FAILED"
}

public enum RollbackReason: String, Codable {
    case readyTimeout = "READY_TIMEOUT"
    case crashed = "CRASHED"
    case reportedByApp = "REPORTED_BY_APP"
}

/// When a downloaded update runs, in the strategies' vocabulary.
public typealias InstallMoment = InstallStrategy

/// One shape for `SyncResult`, `CheckResult` and `DownloadResult`: the status says which fields are set.
public struct SyncResult: Codable, Equatable {
    public let status: SyncStatus
    public let release: Release?
    public let reason: String?
    public let condition: ConditionType?
    public let notes: String?
    public let installAt: InstallMoment?
    public let downloadBytes: Int?
    public let message: String?

    private init(status: SyncStatus, release: Release?, reason: String? = nil, condition: ConditionType? = nil, notes: String? = nil, installAt: InstallMoment? = nil, downloadBytes: Int? = nil, message: String? = nil) {
        self.status = status
        self.release = release
        self.reason = reason
        self.condition = condition
        self.notes = notes
        self.installAt = installAt
        self.downloadBytes = downloadBytes
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case status, release, reason, condition, notes, installAt, downloadBytes, message
    }

    /// The discriminated union's keys per status; a nullable field is an explicit `null`, an optional one absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(release, forKey: .release)
        switch status {
        case .upToDate:
            break
        case .available:
            try container.encode(notes, forKey: .notes)
            try container.encode(downloadBytes, forKey: .downloadBytes)
        case .downloaded:
            try container.encode(notes, forKey: .notes)
        case .updated:
            try container.encode(notes, forKey: .notes)
            try container.encode(installAt, forKey: .installAt)
        case .skipped:
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(condition, forKey: .condition)
        case .failed:
            try container.encode(reason, forKey: .reason)
            try container.encode(message, forKey: .message)
        }
    }

    public static func upToDate(_ release: Release?) -> SyncResult {
        return SyncResult(status: .upToDate, release: release)
    }

    public static func available(_ release: Release, notes: String?, downloadBytes: Int?) -> SyncResult {
        return SyncResult(status: .available, release: release, notes: notes, downloadBytes: downloadBytes)
    }

    public static func downloaded(_ release: Release, notes: String?) -> SyncResult {
        return SyncResult(status: .downloaded, release: release, notes: notes)
    }

    public static func updated(_ release: Release, notes: String?, installAt: InstallMoment) -> SyncResult {
        return SyncResult(status: .updated, release: release, notes: notes, installAt: installAt)
    }

    public static func skipped(_ release: Release?, reason: SkippedReason, condition: ConditionType? = nil) -> SyncResult {
        return SyncResult(status: .skipped, release: release, reason: reason.rawValue, condition: condition)
    }

    public static func failed(_ release: Release?, reason: FailedReason, message: String) -> SyncResult {
        return SyncResult(status: .failed, release: release, reason: reason.rawValue, message: message)
    }
}

public enum ApplyStatus: String, Codable {
    case applied = "APPLIED"
    case nothingToApply = "NOTHING_TO_APPLY"
}

/// What `applyUpdate()` answers: the update is the current release and the reload follows, or nothing waits.
public struct ApplyResult: Codable, Equatable {
    public let status: ApplyStatus
    public let release: Release?

    public init(status: ApplyStatus, release: Release?) {
        self.status = status
        self.release = release
    }

    enum CodingKeys: String, CodingKey {
        case status, release
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(release, forKey: .release)
    }
}

public struct NotifyReadyResult: Codable, Equatable {
    public let currentRelease: Release?
    public let previousRelease: Release?
    public let isRolledBack: Bool
    public let rollbackReason: RollbackReason?

    public init(currentRelease: Release?, previousRelease: Release?, isRolledBack: Bool, rollbackReason: RollbackReason?) {
        self.currentRelease = currentRelease
        self.previousRelease = previousRelease
        self.isRolledBack = isRolledBack
        self.rollbackReason = rollbackReason
    }

    enum CodingKeys: String, CodingKey {
        case currentRelease, previousRelease, isRolledBack, rollbackReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentRelease, forKey: .currentRelease)
        try container.encode(previousRelease, forKey: .previousRelease)
        try container.encode(isRolledBack, forKey: .isRolledBack)
        try container.encodeIfPresent(rollbackReason, forKey: .rollbackReason)
    }
}

public struct LastCheck: Codable, Equatable {
    public let at: Date
    public let trigger: SyncTrigger
    public let result: SyncResult
}

public struct IndexState: Codable, Equatable {
    public let sequence: Int
    public let fetchedAt: Date
}

/// The SDK's state, a snapshot: everything the debug screen shows.
public struct StateResult: Codable, Equatable {
    public let currentRelease: Release?
    public let nextRelease: Release?
    public let fallbackRelease: Release?
    public let embeddedBundleId: String?
    public let lastCheck: LastCheck?
    public let index: IndexState?
    public let failedBundleIds: [String]
    public let lastReportAt: Date?

    enum CodingKeys: String, CodingKey {
        case currentRelease, nextRelease, fallbackRelease, embeddedBundleId, lastCheck, index, failedBundleIds, lastReportAt
    }

    /// Every key of the typed contract, `null` when empty, so `result.currentRelease === null` holds in app code.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentRelease, forKey: .currentRelease)
        try container.encode(nextRelease, forKey: .nextRelease)
        try container.encode(fallbackRelease, forKey: .fallbackRelease)
        try container.encode(embeddedBundleId, forKey: .embeddedBundleId)
        try container.encode(lastCheck, forKey: .lastCheck)
        try container.encode(index, forKey: .index)
        try container.encode(failedBundleIds, forKey: .failedBundleIds)
        try container.encode(lastReportAt, forKey: .lastReportAt)
    }
}

public enum ChannelSource: String, Codable {
    case runtime, config
}

public struct ChannelResult: Codable, Equatable {
    /// `nil` while no id is known: a build without a channel, or a runtime name no sync has resolved yet.
    public let id: String?
    public let name: String?
    public let source: ChannelSource

    enum CodingKeys: String, CodingKey {
        case id, name, source
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
    }
}

public struct DeviceResult: Codable, Equatable {
    public let id: String
    public let platform: String
    public let binaryVersion: String
    public let binaryBuild: String
    public let osVersion: String
    public let sdkVersion: String
    public let fingerprint: String?
    public let channel: ChannelResult
    public let attributes: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, platform, binaryVersion, binaryBuild, osVersion, sdkVersion, fingerprint, channel, attributes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(binaryVersion, forKey: .binaryVersion)
        try container.encode(binaryBuild, forKey: .binaryBuild)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(channel, forKey: .channel)
        try container.encode(attributes, forKey: .attributes)
    }
}

// MARK: Events — what the SDK did on its own; results answer what the app called.

/// A check found a release the device qualifies for.
public struct UpdateAvailableEvent: Codable, Equatable {
    public let release: Release
    public let notes: String?
    public let downloadBytes: Int?
    public let trigger: SyncTrigger

    enum CodingKeys: String, CodingKey {
        case release, notes, downloadBytes, trigger
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(release, forKey: .release)
        try container.encode(notes, forKey: .notes)
        try container.encode(downloadBytes, forKey: .downloadBytes)
        try container.encode(trigger, forKey: .trigger)
    }
}

/// The download completed and the update waits for its install.
public struct UpdateDownloadedEvent: Codable, Equatable {
    public let release: Release
    public let installAt: InstallMoment
    public let trigger: SyncTrigger
}

/// A check or a download failed.
public struct UpdateFailedEvent: Codable, Equatable {
    public let release: Release?
    public let reason: FailedReason
    public let message: String
    public let trigger: SyncTrigger

    enum CodingKeys: String, CodingKey {
        case release, reason, message, trigger
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(release, forKey: .release)
        try container.encode(reason, forKey: .reason)
        try container.encode(message, forKey: .message)
        try container.encode(trigger, forKey: .trigger)
    }
}

/// At each start that follows a rollback until the app is up after one, before the readiness gate; `to` is `null` for the embedded bundle.
public struct RolledBackEvent: Codable, Equatable {
    public let from: Release
    public let to: Release?
    public let reason: RollbackReason

    enum CodingKeys: String, CodingKey {
        case from, to, reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(reason, forKey: .reason)
    }
}
