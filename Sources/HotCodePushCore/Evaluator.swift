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

public struct Skip: Equatable {
    public let reason: SkippedReason
    public let condition: ConditionType?

    public init(reason: SkippedReason, condition: ConditionType? = nil) {
        self.reason = reason
        self.condition = condition
    }
}

/// The per-release verdict, the explanation behind the outcome and the probe's output.
public struct ReleaseVerdict: Equatable {
    public let release: IndexRelease
    public let isEligible: Bool
    public let reason: SkippedReason?
    public let condition: ConditionType?
}

/// The outcome for the device. On `SKIPPED` with `RELEASE_REVOKED`, the release is the one the device resolves to —
/// `nil` for the embedded bundle; on every other `SKIPPED` it is the newest release the device will not take.
public enum Evaluation: Equatable {
    case upToDate(IndexRelease?)
    case available(IndexRelease, isMandatory: Bool)
    case skipped(IndexRelease?, reason: SkippedReason, condition: ConditionType?)
}

/// The outcome with the verdicts behind it, newest release first; an index the device does not evaluate, a capped one, leaves them empty.
public struct IndexEvaluation: Equatable {
    public let outcome: Evaluation
    public let verdicts: [ReleaseVerdict]
}

/// The device protocol's evaluation, the same rules as `@hotcodepush/protocol`'s, pinned by its fixture suite.
public enum Evaluator {
    private static let embeddedReleaseNumber = 0
    /// The components a binary version fills before the build: major, minor and patch.
    private static let binaryVersionMinimumComponents = 3

    public static func evaluate(_ index: ChannelIndex, device: DeviceInfo) -> Evaluation {
        return evaluation(of: index, device: device).outcome
    }

    public static func evaluation(of index: ChannelIndex, device: DeviceInfo) -> IndexEvaluation {
        let currentIndexRelease = device.currentRelease.flatMap { current in index.releases.first { $0.id == current.id } }
        if isDeviceBeyondCap(index, device: device) {
            return IndexEvaluation(outcome: .skipped(nil, reason: .spendingCapReached, condition: nil), verdicts: [])
        }
        let verdicts = index.releases.sorted { $0.number > $1.number }.map { verdict(for: $0, in: index, device: device) }
        return IndexEvaluation(outcome: outcome(of: verdicts, in: index, device: device, currentIndexRelease: currentIndexRelease), verdicts: verdicts)
    }

    private static func outcome(of verdicts: [ReleaseVerdict], in index: ChannelIndex, device: DeviceInfo, currentIndexRelease: IndexRelease?) -> Evaluation {
        let currentNumber = device.currentRelease?.number ?? embeddedReleaseNumber
        let isCurrentRevoked = device.currentRelease.map { isRevoked(id: $0.id, in: index) } ?? false
        let newerVerdict = verdicts.first { $0.release.number > currentNumber && $0.reason != .releaseRevoked }
        let eligibleVerdicts = verdicts.filter(\.isEligible)
        let newerEligible = eligibleVerdicts.first { $0.release.number > currentNumber }
        let olderEligible = eligibleVerdicts.first { $0.release.number < currentNumber }
        if index.isPaused {
            if isCurrentRevoked {
                return .skipped(olderEligible?.release, reason: .releaseRevoked, condition: nil)
            }
            if let newer = newerVerdict {
                return .skipped(newer.release, reason: .channelPaused, condition: nil)
            }
            return .upToDate(currentIndexRelease)
        }
        if let target = newerEligible?.release {
            return .available(target, isMandatory: isMandatoryTransitively(target, currentNumber: currentNumber, eligibleVerdicts: eligibleVerdicts))
        }
        if isCurrentRevoked {
            return .skipped(olderEligible?.release, reason: .releaseRevoked, condition: nil)
        }
        if let newer = newerVerdict, let reason = newer.reason {
            return .skipped(newer.release, reason: reason, condition: newer.condition)
        }
        return .upToDate(currentIndexRelease)
    }

    public static func verdict(for release: IndexRelease, in index: ChannelIndex, device: DeviceInfo) -> ReleaseVerdict {
        if isRevoked(id: release.id, in: index) {
            return ReleaseVerdict(release: release, isEligible: false, reason: .releaseRevoked, condition: nil)
        }
        if release.createdAt < device.builtAt {
            return ReleaseVerdict(release: release, isEligible: false, reason: .releaseOlderThanBinary, condition: nil)
        }
        if device.failedBundleIds.contains(release.bundleId) {
            return ReleaseVerdict(release: release, isEligible: false, reason: .bundleFailedBefore, condition: nil)
        }
        for condition in release.conditions where !isSatisfied(condition, device: device) {
            guard let type = condition.type else {
                return ReleaseVerdict(release: release, isEligible: false, reason: .conditionUnsupported, condition: nil)
            }
            let reason: SkippedReason = (type == .attribute || type == .device) ? .deviceNotTargeted : .deviceIncompatible
            return ReleaseVerdict(release: release, isEligible: false, reason: reason, condition: type)
        }
        if Hashing.rolloutBucket(deviceId: device.deviceId, releaseId: release.id) >= release.rollout {
            return ReleaseVerdict(release: release, isEligible: false, reason: .deviceNotInRollout, condition: nil)
        }
        return ReleaseVerdict(release: release, isEligible: true, reason: nil, condition: nil)
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
        case .fingerprint(let hash):
            return device.fingerprint == hash
        case .os(let range):
            guard let version = VersionRange.parseVersion(device.osVersion) else { return false }
            return VersionRange.isVersionInRange(version, range) == true
        case .unknown:
            return false
        }
    }

    /// The binary version with the build number after it, when both are numbers: a version of fewer than three components
    /// reads with zeros, so the build is always at least the fourth component and `1.0` build `57` is `1.0.0.57`.
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

    /// A release is mandatory for the device when it or any release it skips over is, counting only the releases the device could
    /// take: one a condition, the floor, a revocation, an earlier failure or the rollout keeps from it never makes the move mandatory.
    static func isMandatoryTransitively(_ target: IndexRelease, currentNumber: Int, eligibleVerdicts: [ReleaseVerdict]) -> Bool {
        return eligibleVerdicts.contains { $0.release.isMandatory && $0.release.number > currentNumber && $0.release.number <= target.number }
    }

    static func isRevoked(id: String, in index: ChannelIndex) -> Bool {
        return index.revokedReleaseIds.contains(id)
    }
}
