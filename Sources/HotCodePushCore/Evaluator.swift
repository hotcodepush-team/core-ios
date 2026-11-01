import Foundation

/// What the device knows when it evaluates a channel index.
public struct DeviceInfo: Equatable {
    public let attributes: [String: String]
    public let binaryBuild: String
    public let binaryVersion: String
    /// The floor from the resource file: no release created before it is applied.
    public let builtAt: Date
    /// The running release, or `nil` for the embedded bundle; only its id and number matter here.
    public let currentRelease: Release?
    public let deviceId: String
    public let failedBundleIds: [String]
    public let fingerprint: String?
    public let osVersion: String
    /// The server time of the last acknowledged report, for the spending cap.
    public let reportedAt: Date?

    public init(attributes: [String: String], binaryBuild: String, binaryVersion: String, builtAt: Date, currentRelease: Release?, deviceId: String, failedBundleIds: [String], fingerprint: String?, osVersion: String, reportedAt: Date?) {
        self.attributes = attributes
        self.binaryBuild = binaryBuild
        self.binaryVersion = binaryVersion
        self.builtAt = builtAt
        self.currentRelease = currentRelease
        self.deviceId = deviceId
        self.failedBundleIds = failedBundleIds
        self.fingerprint = fingerprint
        self.osVersion = osVersion
        self.reportedAt = reportedAt
    }
}

/// The per-release verdict, the explanation behind the outcome and the probe's output.
public struct ReleaseVerdict: Equatable {
    public let release: IndexRelease
    public let isEligible: Bool
    public let reason: SkippedReason?
    public let conditionType: ConditionType?
}

/// The outcome for the device.
/// On `skipped` with `release_revoked` the release is the one the device falls back to, `nil` for the embedded bundle.
/// On any other `skipped` it is the newest release the device will not take.
public enum Evaluation: Equatable {
    case upToDate(IndexRelease?)
    case available(IndexRelease, isMandatory: Bool)
    case skipped(IndexRelease?, reason: SkippedReason, conditionType: ConditionType?)
}

/// The outcome with the verdicts behind it, newest release first.
/// A capped index is not evaluated, so its verdicts are empty.
public struct IndexEvaluation: Equatable {
    public let outcome: Evaluation
    public let verdicts: [ReleaseVerdict]
}

/// Evaluates a channel index for the device by the rules of `@hotcodepush/protocol`, pinned by its fixture suite.
public enum Evaluator {
    private static let embeddedReleaseNumber = 0
    // Major, minor and patch come before the build number.
    private static let binaryVersionMinimumComponents = 3

    public static func evaluation(of index: ChannelIndex, device: DeviceInfo) -> IndexEvaluation {
        if isDeviceBeyondCap(index, device: device) {
            return IndexEvaluation(outcome: .skipped(nil, reason: .spendingCapReached, conditionType: nil), verdicts: [])
        }
        let verdicts = index.releases.sorted { $0.number > $1.number }.map { verdict(for: $0, in: index, device: device) }
        return IndexEvaluation(outcome: outcome(of: verdicts, in: index, device: device), verdicts: verdicts)
    }

    private static func outcome(of verdicts: [ReleaseVerdict], in index: ChannelIndex, device: DeviceInfo) -> Evaluation {
        let currentNumber = device.currentRelease?.number ?? embeddedReleaseNumber
        let isCurrentRevoked = device.currentRelease.map { isRevoked(id: $0.id, in: index) } ?? false
        let newerVerdict = verdicts.first { $0.release.number > currentNumber && $0.reason != .releaseRevoked }
        let eligibleVerdicts = verdicts.filter(\.isEligible)
        let newerEligible = eligibleVerdicts.first { $0.release.number > currentNumber }
        let olderEligible = eligibleVerdicts.first { $0.release.number < currentNumber }
        if index.pausedAt == nil, let target = newerEligible?.release {
            return .available(target, isMandatory: isMandatoryTransitively(target, currentNumber: currentNumber, eligibleVerdicts: eligibleVerdicts))
        }
        if isCurrentRevoked {
            return .skipped(olderEligible?.release, reason: .releaseRevoked, conditionType: nil)
        }
        if index.pausedAt != nil, let newer = newerVerdict {
            return .skipped(newer.release, reason: .channelPaused, conditionType: nil)
        }
        if let newer = newerVerdict, let reason = newer.reason {
            return .skipped(newer.release, reason: reason, conditionType: newer.conditionType)
        }
        return .upToDate(device.currentRelease.flatMap { current in index.releases.first { $0.id == current.id } })
    }

    public static func verdict(for release: IndexRelease, in index: ChannelIndex, device: DeviceInfo) -> ReleaseVerdict {
        if isRevoked(id: release.id, in: index) {
            return ReleaseVerdict(release: release, isEligible: false, reason: .releaseRevoked, conditionType: nil)
        }
        if release.createdAt < device.builtAt {
            return ReleaseVerdict(release: release, isEligible: false, reason: .releaseOlderThanBinary, conditionType: nil)
        }
        if device.failedBundleIds.contains(release.bundleId) {
            return ReleaseVerdict(release: release, isEligible: false, reason: .bundleFailedBefore, conditionType: nil)
        }
        for condition in release.conditions where !isSatisfied(condition, device: device) {
            guard let type = condition.type else {
                return ReleaseVerdict(release: release, isEligible: false, reason: .conditionUnsupported, conditionType: nil)
            }
            let reason: SkippedReason = (type == .attribute || type == .device) ? .deviceNotTargeted : .deviceIncompatible
            return ReleaseVerdict(release: release, isEligible: false, reason: reason, conditionType: type)
        }
        if Hashing.rolloutBucket(deviceId: device.deviceId, releaseId: release.id) >= release.rolloutPercent {
            return ReleaseVerdict(release: release, isEligible: false, reason: .deviceNotInRollout, conditionType: nil)
        }
        return ReleaseVerdict(release: release, isEligible: true, reason: nil, conditionType: nil)
    }

    /// Whether the device satisfies the condition; an unknown type never does.
    public static func isSatisfied(_ condition: Condition, device: DeviceInfo) -> Bool {
        switch condition {
        case .attribute(let key, let valueSha256):
            return device.attributes[key].map { Hashing.attributeHash(key: key, value: $0) == valueSha256 } ?? false
        case .binary(let range):
            guard let version = resolveBinaryVersion(device) else { return false }
            return VersionRange.isVersionInRange(version, range) == true
        case .device(let hashedIds):
            return hashedIds.contains(Hashing.deviceIdHash(device.deviceId))
        case .fingerprint(let fingerprint):
            return device.fingerprint == fingerprint
        case .os(let range):
            guard let version = VersionRange.parseVersion(device.osVersion) else { return false }
            return VersionRange.isVersionInRange(version, range) == true
        case .unknown:
            return false
        }
    }

    // A short version is padded with zeros, so `1.0` build `57` reads as `1.0.0.57`.
    static func resolveBinaryVersion(_ device: DeviceInfo) -> [Int]? {
        guard let version = VersionRange.parseVersion(device.binaryVersion) else { return nil }
        guard let build = VersionRange.parseVersion(device.binaryBuild), build.count == 1 else { return version }
        let padding = Array(repeating: 0, count: max(0, binaryVersionMinimumComponents - version.count))
        return version + padding + build
    }

    static func isDeviceBeyondCap(_ index: ChannelIndex, device: DeviceInfo) -> Bool {
        guard let cappedAt = index.cappedAt else { return false }
        guard let reportedAt = device.reportedAt else { return true }
        return reportedAt >= cappedAt
    }

    // Only releases the device could take count, so a release it is kept from never makes the move mandatory.
    static func isMandatoryTransitively(_ target: IndexRelease, currentNumber: Int, eligibleVerdicts: [ReleaseVerdict]) -> Bool {
        return eligibleVerdicts.contains { $0.release.isMandatory && $0.release.number > currentNumber && $0.release.number <= target.number }
    }

    static func isRevoked(id: String, in index: ChannelIndex) -> Bool {
        return index.revokedReleaseIds.contains(id)
    }
}
