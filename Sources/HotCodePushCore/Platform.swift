import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// What the platform knows about the binary and the OS.
public struct DeviceFacts: Equatable {
    public let platform: String
    public let binaryVersion: String
    public let binaryBuild: String
    public let osVersion: String
    public let sdkVersion: String
    public var isDebugBuild: Bool

    public init(platform: String, binaryVersion: String, binaryBuild: String, osVersion: String, sdkVersion: String, isDebugBuild: Bool) {
        self.platform = platform
        self.binaryVersion = binaryVersion
        self.binaryBuild = binaryBuild
        self.osVersion = osVersion
        self.sdkVersion = sdkVersion
        self.isDebugBuild = isDebugBuild
    }
}

#if canImport(UIKit)
extension DeviceFacts {
    /// The facts of the running binary: version and build from the Info.plist, and the OS version.
    /// Pass `isDebugBuild` from the SDK's own `#if DEBUG`: the core ships prebuilt in Release, so its own flag never sees the app's.
    public static func current(sdkVersion: String, isDebugBuild: Bool) -> DeviceFacts {
        let info = Bundle.main.infoDictionary ?? [:]
        return DeviceFacts(
            platform: "ios",
            binaryVersion: info["CFBundleShortVersionString"] as? String ?? "",
            binaryBuild: info["CFBundleVersion"] as? String ?? "",
            osVersion: UIDevice.current.systemVersion,
            sdkVersion: sdkVersion,
            isDebugBuild: isDebugBuild)
    }
}

extension Core {
    /// Follows the app between background and foreground for the lifetime of the core. Call it once, after creating the core.
    public nonisolated func observeAppLifecycle() {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.handleAppPause() }
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.handleAppResume() }
        }
    }
}
#endif

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

/// Receives the five core events; the start and the end of a cycle fire nothing.
public protocol CoreListener: AnyObject {
    func updateAvailable(_ event: UpdateAvailableEvent)
    func updateDownloaded(_ event: UpdateDownloadedEvent)
    func updateFailed(_ event: UpdateFailedEvent)
    func downloadProgress(_ event: DownloadProgressEvent)
    func updateRolledBack(_ event: UpdateRolledBackEvent)
}

public protocol ScheduledTask {
    func cancel()
}

public protocol Scheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () async -> Void) -> ScheduledTask
}

/// The time and the pauses, which the tests replace so that nothing they run waits.
public protocol Clock {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Whether the app runs in the background.
/// The start cannot learn it from a notification: a launch straight into the background, for a push or a background fetch, posts none.
public protocol ApplicationState: Sendable {
    /// Read on the main thread.
    var isInBackground: Bool { get }
}

/// The application state as UIKit reports it; without UIKit the app is in the foreground.
public struct SystemApplicationState: ApplicationState {
    public init() {}

    public var isInBackground: Bool {
        #if canImport(UIKit)
        // `inactive` is a launch on its way to the foreground, which posts no foreground notification.
        // A scene-based app reads `background` while its first scene connects, and UIKit posts the foreground notification right after.
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }
}

/// Whether the connection is metered, as the system path monitor last reported it.
/// Metered is an expensive path, such as cellular or a personal hotspot, or a constrained one in Low Data Mode.
public final class NetworkMonitor {
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var isMetered = false

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.setIsMetered(path.isExpensive || path.isConstrained)
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    public func isConnectionMetered() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isMetered
    }

    private func setIsMetered(_ isMetered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.isMetered = isMetered
    }
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

    /// Checks an attribute value, or the rollback reason of the app, by the rule of the events endpoint.
    /// At most 256 Unicode code points, not UTF-16 units or characters, and no control character (C0, DEL or C1).
    public static func validate(value: String) throws {
        guard isValid(value: value) else {
            throw PlainError("A value is at most \(valueMaximumCodePoints) Unicode code points without a control character")
        }
    }

    static func isValid(value: String) -> Bool {
        return value.unicodeScalars.count <= valueMaximumCodePoints && !value.unicodeScalars.contains(where: WireRule.isControlCharacter)
    }
}
