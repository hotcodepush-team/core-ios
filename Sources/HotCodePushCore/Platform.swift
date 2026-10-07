import Foundation

/// What the platform knows about the binary and the OS.
public struct DeviceFacts: Equatable {
    public let platform: String
    public let binaryVersion: String
    public let binaryBuild: String
    public let osVersion: String
    public let sdkVersion: String
    public let isDebugBuild: Bool

    public init(platform: String, binaryVersion: String, binaryBuild: String, osVersion: String, sdkVersion: String, isDebugBuild: Bool) {
        self.platform = platform
        self.binaryVersion = binaryVersion
        self.binaryBuild = binaryBuild
        self.osVersion = osVersion
        self.sdkVersion = sdkVersion
        self.isDebugBuild = isDebugBuild
    }
}

/// The framework's side of running a bundle: where a bundle is laid out and which one the WebView serves.
public protocol BundleLoader: AnyObject {
    /// The directory a bundle is laid out in by path for the WebView.
    func projectionDirectory(bundleId: String) -> URL
    /// Removes that directory, and with it the links that kept the bundle's files alive.
    func deleteProjection(bundleId: String)
    /// Records which bundle the framework loads at the next start; `nil` is the embedded bundle.
    func persistServedBundle(bundleId: String?)
    /// Points the WebView at the bundle now and reloads it; `nil` is the embedded bundle.
    func loadServedBundle(bundleId: String?)
    /// The bundle the WebView runs right now, `nil` for the embedded bundle.
    func servedBundleId() -> String?
    /// Whether the connection is metered or constrained, for the `unmetered` download strategy.
    func isConnectionMetered() -> Bool
}

/// The five events, named by what happened to the update; a cycle's start and end fire nothing.
public protocol CoreListener: AnyObject {
    func updateAvailable(_ event: UpdateAvailableEvent)
    func updateDownloaded(_ event: UpdateDownloadedEvent)
    func updateFailed(_ event: UpdateFailedEvent)
    func downloadProgress(releaseId: String, downloadedBytes: Int, totalBytes: Int)
    func rolledBack(_ event: RolledBackEvent)
}

public protocol ScheduledTask {
    func cancel()
}

public protocol Scheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () async -> Void) -> ScheduledTask
}

public protocol Clock {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public final class DispatchScheduler: Scheduler {
    private final class ScheduledWorkItem: ScheduledTask {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    public init() {}

    public func schedule(after seconds: TimeInterval, _ block: @escaping () async -> Void) -> ScheduledTask {
        let item = DispatchWorkItem { Task { await block() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        return ScheduledWorkItem(item: item)
    }
}

/// The two programming mistakes the SDK reports with a plain error: nothing an app handles.
public struct PlainError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum AttributeRules {
    static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,64}$")
    static let valueMaximumCodePoints = 256

    public static func validate(key: String, value: String) throws {
        guard isValid(key: key) else {
            throw PlainError("An attribute key is an identifier of letters, digits, '_', '-' and '.', at most 64 characters: \(key)")
        }
        try validate(value: value)
    }

    static func isValid(key: String) -> Bool {
        return keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// The value rule alone, shared with the app's rollback reason: at most 256 Unicode code points, counted neither in UTF-16
    /// code units nor in the characters a reader sees, and no control character, C0, DEL or C1, which the events endpoint refuses.
    public static func validate(value: String) throws {
        guard isValid(value: value) else {
            throw PlainError("A value is at most \(valueMaximumCodePoints) Unicode code points without a control character")
        }
    }

    static func isValid(value: String) -> Bool {
        return value.unicodeScalars.count <= valueMaximumCodePoints && !value.unicodeScalars.contains(where: WireRule.isControlCharacter)
    }
}
