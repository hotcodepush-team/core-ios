import Foundation

/// One line of the session log: the time, a catalog code and a sentence.
/// The log lives in memory behind the debug screen, never on disk and never on the wire.
public struct LogEntry: Equatable {
    public static let capacity = 200

    public let at: Date
    public let code: String
    public let message: String

    static func ofCycle(_ result: SyncResult, trigger: SyncTrigger, at: Date) -> LogEntry {
        let code = [result.status.rawValue, result.reason, result.condition?.rawValue].compactMap { $0 }.joined(separator: " ")
        return LogEntry(at: at, code: code, message: "\(trigger.rawValue): \(resolveCycleSentence(result))")
    }

    // A check event is logged by its cycle already.
    static func ofDeviceEvent(_ event: DeviceEvent, at: Date) -> LogEntry? {
        switch event.type {
        case "downloaded":
            return LogEntry(at: at, code: "downloaded", message: "release \(event.releaseId ?? ""): \(event.downloadSizeBytes ?? 0) bytes as \(event.packKind ?? "") pack")
        case "applied":
            return LogEntry(at: at, code: "applied", message: "release \(event.releaseId ?? "") is the running release")
        case "confirmed":
            return LogEntry(at: at, code: "confirmed", message: "release \(event.releaseId ?? "") passed the readiness gate")
        case "failed":
            return LogEntry(at: at, code: "failed \(event.reason ?? "")", message: "release \(event.releaseId ?? "")\(event.detail.map { ": \($0)" } ?? "")")
        case "rolled_back":
            return LogEntry(at: at, code: "rolled_back", message: "release \(event.fromReleaseId ?? "") rolled back to \(event.toReleaseId ?? "the embedded bundle")")
        default:
            return nil
        }
    }

    static func ofBatch(_ answer: BatchAnswer, eventCount: Int, at: Date) -> LogEntry {
        switch answer {
        case .acknowledged:
            return LogEntry(at: at, code: "reported", message: "\(eventCount) events acknowledged")
        case .refused(let status):
            return LogEntry(at: at, code: "report_refused", message: "\(eventCount) events dropped: HTTP \(status)")
        case .failed(let status?):
            return LogEntry(at: at, code: "report_failed", message: "\(eventCount) events kept for the next sync: HTTP \(status)")
        case .failed(nil):
            return LogEntry(at: at, code: "report_failed", message: "\(eventCount) events kept for the next sync: the events endpoint could not be reached")
        }
    }

    private static func resolveCycleSentence(_ result: SyncResult) -> String {
        let release = result.release.map { "release #\($0.number) (\($0.bundleVersion))" }
        switch result.status {
        case .upToDate: return "\(release ?? "the embedded bundle") is current"
        case .available: return "\(release ?? "a release") is available"
        case .downloaded where result.applyStrategy == .manual: return "\(release ?? "a release") is downloaded and waits for applyUpdate()"
        case .downloaded: return "\(release ?? "a release") is downloaded and applies at \(result.applyStrategy?.rawValue ?? "")"
        case .applied: return "\(release ?? "a release") is applied and the app reloads"
        case .skipped: return "\(release ?? "the newest release") is not taken"
        case .failed: return result.message ?? ""
        }
    }
}
