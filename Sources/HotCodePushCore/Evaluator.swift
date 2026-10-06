import Foundation

/// What the device knows when it evaluates a channel index.
public struct DeviceInfo: Equatable {
    /// The sequence of the index the device has already evaluated; an older index is ignored.
    public let appliedIndexSequence: Int?
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
    public let runtimeVersion: String?

    public init(appliedIndexSequence: Int?, attributes: [String: String], binaryBuild: String, binaryVersion: String, builtAt: Date, currentRelease: Release?, deviceId: String, failedBundleIds: [String], fingerprint: String?, osVersion: String, reportedAt: Date?, runtimeVersion: String?) {
        self.appliedIndexSequence = appliedIndexSequence
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
        self.runtimeVersion = runtimeVersion
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

/// The outcome with the verdicts behind it, newest release first; an index the device does not evaluate — older than the applied one, or capped — leaves them empty.
public struct IndexEvaluation: Equatable {
    public let outcome: Evaluation
    public let verdicts: [ReleaseVerdict]
}

/// The device protocol's evaluation, the same rules as `@hotcodepush/protocol`'s, pinned by its fixture suite.
public enum Evaluator {
    private static let embeddedReleaseNumber = 0

    public static func evaluate(_ index: ChannelIndex, device: DeviceInfo) -> Evaluation {
        return evaluation(of: index, device: device).outcome
    }

    public static func evaluation(of index: ChannelIndex, device: DeviceInfo) -> IndexEvaluation {
        let currentIndexRelease = device.currentRelease.flatMap { current in index.releases.first { $0.id == current.id } }
        if let applied = device.appliedIndexSequence, index.sequence < applied {
            return IndexEvaluation(outcome: .upToDate(currentIndexRelease), verdicts: [])
        }
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
        let newerEligible = verdicts.first { $0.isEligible && $0.release.number > currentNumber }
        let olderEligible = verdicts.first { $0.isEligible && $0.release.number < currentNumber }
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
            return .available(target, isMandatory: isMandatoryTransitively(target, currentNumber: currentNumber, verdicts: verdicts))
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
            return ReleaseVerdict(release: release, isEligible: false, reason: .olderThanBinary, condition: nil)
        }
        if device.failedBundleIds.contains(release.bundleId) {
            return ReleaseVerdict(release: release, isEligible: false, reason: .failedBefore, condition: nil)
        }
        for condition in release.conditions where !isSatisfied(condition, device: device) {
            guard let type = condition.type else {
                return ReleaseVerdict(release: release, isEligible: false, reason: .unsupportedCondition, condition: nil)
            }
            let reason: SkippedReason = (type == .attribute || type == .device) ? .notTargeted : .incompatible
            return ReleaseVerdict(release: release, isEligible: false, reason: reason, condition: type)
        }
        if Hashing.rolloutBucket(deviceId: device.deviceId, releaseId: release.id) >= release.rollout {
            return ReleaseVerdict(release: release, isEligible: false, reason: .notInRollout, condition: nil)
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
        case .runtime(let version):
            return device.runtimeVersion == version
        case .unknown:
            return false
        }
    }

    /// The binary version with the build number as its fourth component, when both are numbers.
    static func resolveBinaryVersion(_ device: DeviceInfo) -> [Int]? {
        guard let version = VersionRange.parseVersion(device.binaryVersion) else { return nil }
        if let build = VersionRange.parseVersion(device.binaryBuild), build.count == 1 {
            return version + build
        }
        return version
    }

    static func isDeviceBeyondCap(_ index: ChannelIndex, device: DeviceInfo) -> Bool {
        guard let cappedAt = index.cappedAt else { return false }
        guard let reportedAt = device.reportedAt else { return true }
        return reportedAt >= cappedAt
    }

    /// A release is mandatory for the device when it or any release it skipped over is.
    static func isMandatoryTransitively(_ target: IndexRelease, currentNumber: Int, verdicts: [ReleaseVerdict]) -> Bool {
        return verdicts.contains { $0.release.isMandatory && $0.release.number > currentNumber && $0.release.number <= target.number }
    }

    static func isRevoked(id: String, in index: ChannelIndex) -> Bool {
        return index.revokedReleaseIds.contains(id)
    }
}
