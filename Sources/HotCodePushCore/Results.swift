import Foundation

public enum SyncTrigger: String, CaseIterable, Codable {
    case start, resume, interval, manual
}

public enum SyncStatus: String, CaseIterable, Codable {
    case upToDate = "up_to_date"
    case available
    case downloaded
    case applied
    case skipped
    case failed
}

public enum SkippedReason: String, CaseIterable, Codable {
    case buildDebug = "build_debug"
    case bundleFailedBefore = "bundle_failed_before"
    case channelPaused = "channel_paused"
    case conditionUnsupported = "condition_unsupported"
    case connectionMetered = "connection_metered"
    case deviceIncompatible = "device_incompatible"
    case deviceNotInRollout = "device_not_in_rollout"
    case deviceNotTargeted = "device_not_targeted"
    case releaseOlderThanBinary = "release_older_than_binary"
    case releaseRevoked = "release_revoked"
    case spendingCapReached = "spending_cap_reached"
}

public enum FailedReason: String, CaseIterable, Codable {
    case channelUnknown = "channel_unknown"
    case contentMismatched = "content_mismatched"
    case deviceOffline = "device_offline"
    case downloadFailed = "download_failed"
    case indexInvalid = "index_invalid"
    case manifestInvalid = "manifest_invalid"
    case signatureInvalid = "signature_invalid"
}

public enum RollbackReason: String, CaseIterable, Codable {
    case appCrashed = "app_crashed"
    case appRequested = "app_requested"
    case readinessTimedOut = "readiness_timed_out"
}

/// The answer of `sync()`, `checkForUpdate()` and `downloadUpdate()`; the status says which fields are set.
/// `available` leaves the download to the app, `downloaded` waits for the moment in `applyStrategy`, and `applied` reloads after the result.
public struct SyncResult: Codable, Equatable {
    public let status: SyncStatus
    public let release: Release?
    public let reason: String?
    public let condition: ConditionType?
    public let notes: String?
    /// `next_start`, `next_resume` or `manual` on `downloaded`, never `immediate`, which answers `applied`.
    public let applyStrategy: ApplyStrategy?
    public let downloadSizeBytes: Int?
    public let message: String?

    private init(status: SyncStatus, release: Release?, reason: String? = nil, condition: ConditionType? = nil, notes: String? = nil, applyStrategy: ApplyStrategy? = nil, downloadSizeBytes: Int? = nil, message: String? = nil) {
        self.status = status
        self.release = release
        self.reason = reason
        self.condition = condition
        self.notes = notes
        self.applyStrategy = applyStrategy
        self.downloadSizeBytes = downloadSizeBytes
        self.message = message
    }

    /// Writes the keys of its status only: a nullable field as an explicit `null`, an optional one left out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(release, forKey: .release)
        switch status {
        case .upToDate:
            break
        case .available:
            try container.encode(notes, forKey: .notes)
            try container.encode(downloadSizeBytes, forKey: .downloadSizeBytes)
        case .downloaded:
            try container.encode(notes, forKey: .notes)
            try container.encode(applyStrategy, forKey: .applyStrategy)
        case .applied:
            try container.encode(notes, forKey: .notes)
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

    public static func available(_ release: Release, notes: String?, downloadSizeBytes: Int?) -> SyncResult {
        return SyncResult(status: .available, release: release, notes: notes, downloadSizeBytes: downloadSizeBytes)
    }

    public static func downloaded(_ release: Release, notes: String?, applyStrategy: ApplyStrategy) -> SyncResult {
        return SyncResult(status: .downloaded, release: release, notes: notes, applyStrategy: applyStrategy)
    }

    public static func applied(_ release: Release, notes: String?) -> SyncResult {
        return SyncResult(status: .applied, release: release, notes: notes)
    }

    public static func skipped(_ release: Release?, reason: SkippedReason, condition: ConditionType? = nil) -> SyncResult {
        return SyncResult(status: .skipped, release: release, reason: reason.rawValue, condition: condition)
    }

    public static func failed(_ release: Release?, reason: FailedReason, message: String) -> SyncResult {
        return SyncResult(status: .failed, release: release, reason: reason.rawValue, message: message)
    }
}

public enum ApplyStatus: String, CaseIterable, Codable {
    case applied
    case nothingToApply = "nothing_to_apply"
}

/// What `applyUpdate()` answers: the update is the current release and the reload follows, or nothing waits.
public struct ApplyUpdateResult: Codable, Equatable {
    public let status: ApplyStatus
    public let release: Release?

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentRelease, forKey: .currentRelease)
        try container.encode(previousRelease, forKey: .previousRelease)
        try container.encode(isRolledBack, forKey: .isRolledBack)
        try container.encodeIfPresent(rollbackReason, forKey: .rollbackReason)
    }
}

public struct LastCheck: Codable, Equatable {
    public let checkedAt: Date
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
    /// The server time of the month's first acknowledged report, for the spending cap.
    public let reportedAt: Date?

    /// Writes every key, `null` when empty, so `result.currentRelease === null` holds in app code.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentRelease, forKey: .currentRelease)
        try container.encode(nextRelease, forKey: .nextRelease)
        try container.encode(fallbackRelease, forKey: .fallbackRelease)
        try container.encode(embeddedBundleId, forKey: .embeddedBundleId)
        try container.encode(lastCheck, forKey: .lastCheck)
        try container.encode(index, forKey: .index)
        try container.encode(failedBundleIds, forKey: .failedBundleIds)
        try container.encode(reportedAt, forKey: .reportedAt)
    }
}

public enum ChannelSource: String, CaseIterable, Codable {
    case runtime, config
}

public struct ChannelResult: Codable, Equatable {
    /// `nil` while no id is known: a build without a channel, or a runtime name no sync has resolved yet.
    public let id: String?
    public let name: String?
    public let source: ChannelSource

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

/// A check found a release the device qualifies for.
public struct UpdateAvailableEvent: Codable, Equatable {
    public let release: Release
    public let notes: String?
    public let downloadSizeBytes: Int?
    public let trigger: SyncTrigger

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(release, forKey: .release)
        try container.encode(notes, forKey: .notes)
        try container.encode(downloadSizeBytes, forKey: .downloadSizeBytes)
        try container.encode(trigger, forKey: .trigger)
    }
}

/// The download completed; `applyStrategy` says when the update is applied, `manual` meaning the app's `applyUpdate()`.
public struct UpdateDownloadedEvent: Codable, Equatable {
    public let release: Release
    public let applyStrategy: ApplyStrategy
    public let trigger: SyncTrigger
}

/// A check or a download failed.
public struct UpdateFailedEvent: Codable, Equatable {
    public let release: Release?
    public let reason: FailedReason
    public let message: String
    public let trigger: SyncTrigger

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(release, forKey: .release)
        try container.encode(reason, forKey: .reason)
        try container.encode(message, forKey: .message)
        try container.encode(trigger, forKey: .trigger)
    }
}

/// While a pack downloads: `progressBytes` of its `downloadSizeBytes` have arrived, `progress` their share from 0 to 1.
public struct DownloadProgressEvent: Codable, Equatable {
    public let downloadSizeBytes: Int
    public let progress: Double
    public let progressBytes: Int
    public let releaseId: String

    init(downloadSizeBytes: Int, progressBytes: Int, releaseId: String) {
        self.downloadSizeBytes = downloadSizeBytes
        self.progress = downloadSizeBytes > 0 ? Double(progressBytes) / Double(downloadSizeBytes) : 0
        self.progressBytes = progressBytes
        self.releaseId = releaseId
    }
}

/// Sent at each start after a rollback until the app is up, before the readiness gate.
/// `toRelease` is `null` for the embedded bundle.
public struct UpdateRolledBackEvent: Codable, Equatable {
    public let fromRelease: Release
    public let toRelease: Release?
    public let reason: RollbackReason

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromRelease, forKey: .fromRelease)
        try container.encode(toRelease, forKey: .toRelease)
        try container.encode(reason, forKey: .reason)
    }
}
