import Foundation

/// One line of this session's log: when, the code from the catalog, and the sentence behind it. The log lives in memory
/// behind the debug screen, never on disk and never on the wire.
public struct LogEntry: Equatable {
    public static let capacity = 200

    public let at: Date
    public let code: String
    public let message: String

    public init(at: Date, code: String, message: String) {
        self.at = at
        self.code = code
        self.message = message
    }

    /// A cycle's result: the status, the reason and the condition as the code, the trigger and the release in the sentence.
    static func ofCycle(_ result: SyncResult, trigger: SyncTrigger, at: Date) -> LogEntry {
        let code = [result.status.rawValue, result.reason, result.condition?.rawValue].compactMap { $0 }.joined(separator: " ")
        return LogEntry(at: at, code: code, message: "\(trigger.rawValue): \(resolveCycleSentence(result))")
    }

    /// An outcome event as it enters the outbox; a check event is the cycle's line already.
    static func ofDeviceEvent(_ event: DeviceEvent, at: Date) -> LogEntry? {
        switch event.type {
        case "downloaded":
            return LogEntry(at: at, code: "DOWNLOADED", message: "release \(event.releaseId ?? ""): \(event.bytes ?? 0) bytes as \(event.packKind ?? "") pack")
        case "applied":
            return LogEntry(at: at, code: "APPLIED", message: "release \(event.releaseId ?? "") is the running release")
        case "confirmed":
            return LogEntry(at: at, code: "CONFIRMED", message: "release \(event.releaseId ?? "") passed the readiness gate")
        case "failed":
            return LogEntry(at: at, code: "FAILED \(event.reason ?? "")", message: "release \(event.releaseId ?? "")\(event.detail.map { ": \($0)" } ?? "")")
        case "rolledBack":
            return LogEntry(at: at, code: "ROLLED_BACK", message: "release \(event.fromReleaseId ?? "") rolled back to \(event.toReleaseId ?? "the embedded bundle")")
        default:
            return nil
        }
    }

    static func ofReport(eventCount: Int, status: Int?, at: Date) -> LogEntry {
        guard let status = status else { return LogEntry(at: at, code: "REPORT_FAILED", message: "\(eventCount) events kept for the next sync: the events endpoint could not be reached") }
        guard status == 202 else { return LogEntry(at: at, code: "REPORT_FAILED", message: "\(eventCount) events kept for the next sync: HTTP \(status)") }
        return LogEntry(at: at, code: "REPORTED", message: "\(eventCount) events acknowledged")
    }

    private static func resolveCycleSentence(_ result: SyncResult) -> String {
        let release = result.release.map { "release #\($0.number) (\($0.bundleVersion))" }
        switch result.status {
        case .upToDate: return "\(release ?? "the embedded bundle") is current"
        case .available: return "\(release ?? "a release") is available"
        case .downloaded: return "\(release ?? "a release") is downloaded and waits for applyUpdate()"
        case .updated: return "\(release ?? "a release") installs \(result.installAt?.rawValue ?? "")"
        case .skipped: return "\(release ?? "the newest release") is not taken"
        case .failed: return result.message ?? ""
        }
    }
}
