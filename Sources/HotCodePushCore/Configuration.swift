import Foundation

/// When a downloaded update is applied.
public enum ApplyStrategy: String, CaseIterable, Codable {
    case immediate
    case manual
    case nextResume = "next_resume"
    case nextStart = "next_start"
}

/// Whether the SDK checks on its own, at start, on resume and at the interval; `manual` leaves every cycle to the app's `sync()`.
public enum CheckStrategy: String, CaseIterable, Codable {
    case auto
    case manual
}

/// When an update the check found is downloaded; `manual` stops the cycle after the check.
public enum DownloadStrategy: String, CaseIterable, Codable {
    case auto
    case manual
    case unmetered
}

/// When a mandatory update is applied; `next_start` is excluded, since it would make the flag mean nothing.
public enum MandatoryApplyStrategy: String, CaseIterable, Codable {
    case immediate
    case manual
}

extension ApplyStrategy {
    /// A mandatory strategy in the apply strategies' vocabulary, which holds both of its values.
    init(_ strategy: MandatoryApplyStrategy) {
        switch strategy {
        case .immediate: self = .immediate
        case .manual: self = .manual
        }
    }
}

/// What ends the readiness gate: the first render, or an explicit `notifyReady()`.
public enum ReadySignal: String, CaseIterable, Codable {
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
    /// The least time in the background before a `next_resume` apply.
    public var nextResumeMinimumBackgroundSeconds: Double
    public var readySignal: ReadySignal
    public var readyTimeoutSeconds: Double
    public var isEnabledInDebugBuilds: Bool
    public var publicKeys: [DevicePublicKey]
    public var builtAt: Date
    public var fingerprint: String?
    /// The embedded bundle's files; `nil` in a build that bundled no JavaScript, which embeds no bundle and never updates.
    public var embeddedBundleManifest: EmbeddedBundleManifest?
    public var embeddedBundleId: String?
    public var filesBaseUrl: String
    public var updatesBaseUrl: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(.identifier, forKey: .appId)
        channelId = try container.decodeNullable(.nonEmpty, forKey: .channelId)
        checkStrategy = try container.decodeIfPresent(CheckStrategy.self, forKey: .checkStrategy) ?? .auto
        checkIntervalSeconds = try container.decodeSeconds(forKey: .checkIntervalSeconds, minimum: Configuration.minimumCheckIntervalSeconds, default: 900)
        downloadStrategy = try container.decodeIfPresent(DownloadStrategy.self, forKey: .downloadStrategy) ?? .auto
        applyStrategy = try container.decodeIfPresent(ApplyStrategy.self, forKey: .applyStrategy) ?? .nextStart
        mandatoryApplyStrategy = try container.decodeIfPresent(MandatoryApplyStrategy.self, forKey: .mandatoryApplyStrategy) ?? .immediate
        nextResumeMinimumBackgroundSeconds = try container.decodeSeconds(forKey: .nextResumeMinimumBackgroundSeconds, minimum: 0, default: 300)
        readySignal = try container.decodeIfPresent(ReadySignal.self, forKey: .readySignal) ?? .render
        readyTimeoutSeconds = try container.decodeSeconds(forKey: .readyTimeoutSeconds, minimum: Configuration.minimumReadyTimeoutSeconds, default: 10)
        isEnabledInDebugBuilds = try container.decodeIfPresent(Bool.self, forKey: .isEnabledInDebugBuilds) ?? true
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

    /// Why an SDK runs without a core when the app's resources lack the resource file.
    public static let missingMessage = "HotCodePush is not configured: hotcodepush.json is missing from the app's resources. Run `npx hotcodepush init` and build the app once."

    public static func decode(_ data: Data) throws -> Configuration {
        return try Json.decoder.decode(Configuration.self, from: data)
    }

    /// The resource file the build wrote into the bundle's resources, `nil` when they lack it; a file the reader refuses throws its error.
    public static func read(from bundle: Bundle = .main, subdirectory: String? = nil) throws -> Configuration? {
        guard let url = bundle.url(forResource: "hotcodepush", withExtension: "json", subdirectory: subdirectory) else {
            return nil
        }
        return try decode(Data(contentsOf: url))
    }

    /// Why an SDK runs without a core when the reader refused the resource file, in the reader's words: a decoding error's
    /// `localizedDescription` hides them behind a generic sentence.
    public static func resolveRefusedMessage(_ error: Error) -> String {
        let reason: String
        switch error as? DecodingError {
        case .dataCorrupted(let context)?, .keyNotFound(_, let context)?, .typeMismatch(_, let context)?, .valueNotFound(_, let context)?:
            reason = context.debugDescription
        default:
            reason = error.localizedDescription
        }
        return "HotCodePush is not configured: the app's hotcodepush.json was refused: \(reason). Check the project's hotcodepush.json and build the app again."
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

/// The apply strategies for one `downloadUpdate()` call, overriding the configuration; the download strategy is pinned to `auto`.
public struct DownloadUpdateOptions: Equatable {
    public var applyStrategy: ApplyStrategy?
    public var mandatoryApplyStrategy: MandatoryApplyStrategy?

    public init(applyStrategy: ApplyStrategy? = nil, mandatoryApplyStrategy: MandatoryApplyStrategy? = nil) {
        self.applyStrategy = applyStrategy
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
