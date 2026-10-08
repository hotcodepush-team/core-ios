import Foundation

/// When a downloaded update is applied.
public enum ApplyStrategy: String, Codable {
    case immediate
    case manual
    case nextResume = "next-resume"
    case nextStart = "next-start"
}

/// Whether the SDK checks on its own, at start, on resume and at the interval; `manual` leaves every cycle to the app's `sync()`.
public enum CheckStrategy: String, Codable {
    case auto
    case manual
}

/// When an update the check found is downloaded; `manual` stops the cycle after the check.
public enum DownloadStrategy: String, Codable {
    case auto
    case manual
    case unmetered
}

/// When a mandatory update is applied; `next-start` is excluded, since it would make the flag mean nothing.
public enum MandatoryApplyStrategy: String, Codable {
    case immediate
    case manual
}

/// What ends the readiness gate: the first render, or an explicit `notifyReady()`.
public enum ReadySignal: String, Codable {
    case manual
    case render
}

/// The resource file: the project's `hotcodepush.json` with the channel resolved to its id, plus what only the embed step knows.
public struct Configuration: Codable, Equatable {
    public static let defaultFilesBaseUrl = "https://files.hotcodepush.com"
    public static let defaultUpdatesBaseUrl = "https://updates.hotcodepush.com"
    /// The floor of `checkIntervalSeconds`: a zero made the core check in a tight loop.
    static let minimumCheckIntervalSeconds: Double = 60
    /// The floor of `readyTimeoutSeconds`: the readiness gate has no off switch.
    static let minimumReadyTimeoutSeconds: Double = 1

    public var appId: String
    /// The channel the build follows; `nil` in a build whose build step ran without a token or offline and never resolved the channel's name.
    public var channelId: String?
    public var checkStrategy: CheckStrategy
    public var checkIntervalSeconds: Double
    public var downloadStrategy: DownloadStrategy
    public var applyStrategy: ApplyStrategy
    public var mandatoryApplyStrategy: MandatoryApplyStrategy
    /// The least time in the background before a `next-resume` apply.
    public var applyOnResumeAfterSeconds: Double
    public var readySignal: ReadySignal
    public var readyTimeoutSeconds: Double
    public var enabledInDebugBuilds: Bool
    public var publicKeys: [DevicePublicKey]
    public var builtAt: Date
    public var fingerprint: String?
    /// The embedded bundle's files; `nil` in a build that bundled no JavaScript, which embeds no bundle and never updates.
    public var embeddedBundleManifest: EmbeddedBundleManifest?
    public var embeddedBundleId: String?
    public var filesBaseUrl: String
    public var updatesBaseUrl: String

    enum CodingKeys: String, CodingKey {
        case appId, channelId, checkStrategy, checkIntervalSeconds, downloadStrategy, applyStrategy, mandatoryApplyStrategy
        case applyOnResumeAfterSeconds, readySignal, readyTimeoutSeconds, enabledInDebugBuilds, publicKeys, builtAt
        case fingerprint, embeddedBundleManifest, embeddedBundleId, filesBaseUrl, updatesBaseUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(.identifier, forKey: .appId)
        channelId = try container.decodeNullable(.nonEmpty, forKey: .channelId)
        checkStrategy = try container.decodeIfPresent(CheckStrategy.self, forKey: .checkStrategy) ?? .auto
        checkIntervalSeconds = try container.decodeSeconds(forKey: .checkIntervalSeconds, minimum: Configuration.minimumCheckIntervalSeconds, default: 900)
        downloadStrategy = try container.decodeIfPresent(DownloadStrategy.self, forKey: .downloadStrategy) ?? .auto
        applyStrategy = try container.decodeIfPresent(ApplyStrategy.self, forKey: .applyStrategy) ?? .nextStart
        mandatoryApplyStrategy = try container.decodeIfPresent(MandatoryApplyStrategy.self, forKey: .mandatoryApplyStrategy) ?? .immediate
        applyOnResumeAfterSeconds = try container.decodeSeconds(forKey: .applyOnResumeAfterSeconds, minimum: 0, default: 300)
        readySignal = try container.decodeIfPresent(ReadySignal.self, forKey: .readySignal) ?? .render
        readyTimeoutSeconds = try container.decodeSeconds(forKey: .readyTimeoutSeconds, minimum: Configuration.minimumReadyTimeoutSeconds, default: 10)
        enabledInDebugBuilds = try container.decodeIfPresent(Bool.self, forKey: .enabledInDebugBuilds) ?? true
        publicKeys = try container.decodeIfPresent([DevicePublicKey].self, forKey: .publicKeys) ?? []
        builtAt = try container.decode(Date.self, forKey: .builtAt)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        embeddedBundleManifest = try container.decodeNullable(EmbeddedBundleManifest.self, forKey: .embeddedBundleManifest)
        embeddedBundleId = try container.decodeIfPresent(.identifier, forKey: .embeddedBundleId)
        filesBaseUrl = try container.decodeIfPresent(.url, forKey: .filesBaseUrl) ?? Configuration.defaultFilesBaseUrl
        updatesBaseUrl = try container.decodeIfPresent(.url, forKey: .updatesBaseUrl) ?? Configuration.defaultUpdatesBaseUrl
    }

    /// Whether a manifest, pack or delta URL lies under the files or the updates host: it starts with the base URL and a `/`, so
    /// another scheme, userinfo, a look-alike host, another port or another path is off the host.
    public func isOnConfiguredHost(_ url: String) -> Bool {
        return [filesBaseUrl, updatesBaseUrl].contains { url.hasPrefix("\($0)/") }
    }

    public static func decode(_ data: Data) throws -> Configuration {
        return try Json.decoder.decode(Configuration.self, from: data)
    }
}

/// Each stage's strategy for one `sync()` call, overriding the configuration.
public struct SyncOptions: Equatable {
    public var applyStrategy: ApplyStrategy?
    public var downloadStrategy: DownloadStrategy?
    public var mandatoryApplyStrategy: MandatoryApplyStrategy?

    public init(applyStrategy: ApplyStrategy? = nil, downloadStrategy: DownloadStrategy? = nil, mandatoryApplyStrategy: MandatoryApplyStrategy? = nil) {
        self.applyStrategy = applyStrategy
        self.downloadStrategy = downloadStrategy
        self.mandatoryApplyStrategy = mandatoryApplyStrategy
    }
}

private extension KeyedDecodingContainer {
    /// A duration in seconds, the default when the file leaves it out; one below its floor refuses the file, never clamped.
    func decodeSeconds(forKey key: Key, minimum: Double, default defaultSeconds: Double) throws -> Double {
        let seconds = try decodeIfPresent(Double.self, forKey: key) ?? defaultSeconds
        guard seconds >= minimum else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(key.stringValue) is below its floor of \(minimum) seconds: \(seconds)")
        }
        return seconds
    }
}
