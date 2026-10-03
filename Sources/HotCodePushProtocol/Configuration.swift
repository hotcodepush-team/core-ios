import Foundation

/// When a downloaded update is applied.
public enum InstallStrategy: String, Codable {
    case immediate
    case manual
    case nextResume = "next-resume"
    case nextStart = "next-start"
}

/// When a mandatory update is applied; `next-start` is excluded, since it would make the flag mean nothing.
public enum MandatoryInstallStrategy: String, Codable {
    case immediate
    case manual
}

/// When an update the check found is downloaded; `manual` stops the cycle after the check.
public enum DownloadStrategy: String, Codable {
    case auto
    case manual
    case unmetered
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

    public var appId: String
    public var channelId: String
    public var autoCheck: Bool
    public var checkInterval: Double
    public var downloadStrategy: DownloadStrategy
    public var installStrategy: InstallStrategy
    public var mandatoryInstallStrategy: MandatoryInstallStrategy
    public var installOnResumeAfter: Double
    public var readySignal: ReadySignal
    public var readyTimeout: Double
    public var enabledInDebugBuilds: Bool
    public var publicKeys: [String]
    public var builtAt: Date
    public var fingerprint: String?
    public var embeddedBundleManifest: BundleManifest
    public var embeddedBundleId: String?
    public var filesBaseUrl: String
    public var updatesBaseUrl: String

    enum CodingKeys: String, CodingKey {
        case appId, channelId, autoCheck, checkInterval, downloadStrategy, installStrategy, mandatoryInstallStrategy
        case installOnResumeAfter, readySignal, readyTimeout, enabledInDebugBuilds, publicKeys, builtAt
        case fingerprint, embeddedBundleManifest, embeddedBundleId, filesBaseUrl, updatesBaseUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(String.self, forKey: .appId)
        channelId = try container.decode(String.self, forKey: .channelId)
        autoCheck = try container.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? true
        checkInterval = try container.decodeIfPresent(Double.self, forKey: .checkInterval) ?? 900
        downloadStrategy = try container.decodeIfPresent(DownloadStrategy.self, forKey: .downloadStrategy) ?? .auto
        installStrategy = try container.decodeIfPresent(InstallStrategy.self, forKey: .installStrategy) ?? .nextStart
        mandatoryInstallStrategy = try container.decodeIfPresent(MandatoryInstallStrategy.self, forKey: .mandatoryInstallStrategy) ?? .immediate
        installOnResumeAfter = try container.decodeIfPresent(Double.self, forKey: .installOnResumeAfter) ?? 300
        readySignal = try container.decodeIfPresent(ReadySignal.self, forKey: .readySignal) ?? .render
        readyTimeout = max(1, try container.decodeIfPresent(Double.self, forKey: .readyTimeout) ?? 10)
        enabledInDebugBuilds = try container.decodeIfPresent(Bool.self, forKey: .enabledInDebugBuilds) ?? true
        publicKeys = try container.decodeIfPresent([String].self, forKey: .publicKeys) ?? []
        builtAt = try container.decode(Date.self, forKey: .builtAt)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        embeddedBundleManifest = try container.decode(BundleManifest.self, forKey: .embeddedBundleManifest)
        embeddedBundleId = try container.decodeIfPresent(String.self, forKey: .embeddedBundleId)
        filesBaseUrl = try container.decodeIfPresent(String.self, forKey: .filesBaseUrl) ?? Configuration.defaultFilesBaseUrl
        updatesBaseUrl = try container.decodeIfPresent(String.self, forKey: .updatesBaseUrl) ?? Configuration.defaultUpdatesBaseUrl
    }

    public static func decode(_ data: Data) throws -> Configuration {
        return try Json.decoder.decode(Configuration.self, from: data)
    }
}

/// Each stage's strategy for one `sync()` call, overriding the configuration.
public struct SyncOptions: Equatable {
    public var downloadStrategy: DownloadStrategy?
    public var installStrategy: InstallStrategy?
    public var mandatoryInstallStrategy: MandatoryInstallStrategy?

    public init(downloadStrategy: DownloadStrategy? = nil, installStrategy: InstallStrategy? = nil, mandatoryInstallStrategy: MandatoryInstallStrategy? = nil) {
        self.downloadStrategy = downloadStrategy
        self.installStrategy = installStrategy
        self.mandatoryInstallStrategy = mandatoryInstallStrategy
    }
}
