import Foundation

/// Everything the debug screen shows, read from the core in one call.
public struct DebugSnapshot: Equatable {
    public let takenAt: Date
    public let device: DeviceResult
    public let configuration: Configuration
    public let isDebugBuild: Bool
    public let state: StateResult
    public let log: [LogEntry]

    public init(takenAt: Date, device: DeviceResult, configuration: Configuration, isDebugBuild: Bool, state: StateResult, log: [LogEntry]) {
        self.takenAt = takenAt
        self.device = device
        self.configuration = configuration
        self.isDebugBuild = isDebugBuild
        self.state = state
        self.log = log
    }
}

public struct DebugRow: Equatable {
    public let label: String
    public let value: String
}

public struct DebugSection: Equatable {
    public let title: String
    public let rows: [DebugRow]
}

/// The debug screen's content as sections of label and value, and the same content as the text the share sheet carries.
public enum DebugReport {
    public static func sections(of snapshot: DebugSnapshot) -> [DebugSection] {
        return [
            deviceSection(snapshot),
            channelSection(snapshot),
            releasesSection(snapshot),
            lastCheckSection(snapshot),
            indexSection(snapshot),
            configurationSection(snapshot),
            logSection(snapshot)
        ]
    }

    public static func text(of snapshot: DebugSnapshot) -> String {
        var lines = ["HotCodePush debug report, \(Iso8601.format(snapshot.takenAt))"]
        for section in sections(of: snapshot) {
            lines.append("")
            lines.append(section.title)
            for row in section.rows {
                lines.append("  \(row.label): \(row.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func deviceSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let device = snapshot.device
        let attributes = device.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return DebugSection(title: "Device", rows: [
            DebugRow(label: "Device id", value: device.id),
            DebugRow(label: "Platform", value: device.platform),
            DebugRow(label: "Binary", value: "\(device.binaryVersion) (\(device.binaryBuild))"),
            DebugRow(label: "OS", value: device.osVersion),
            DebugRow(label: "SDK", value: device.sdkVersion),
            DebugRow(label: "Fingerprint", value: device.fingerprint ?? "none"),
            DebugRow(label: "Debug build", value: snapshot.isDebugBuild ? "yes" : "no"),
            DebugRow(label: "Attributes", value: attributes.isEmpty ? "none" : attributes.joined(separator: ", "))
        ])
    }

    private static func channelSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let channel = snapshot.device.channel
        return DebugSection(title: "Channel", rows: [
            DebugRow(label: "Channel id", value: channel.id.isEmpty ? "unresolved" : channel.id),
            DebugRow(label: "Name", value: channel.name ?? "none"),
            DebugRow(label: "Source", value: channel.source.rawValue)
        ])
    }

    private static func releasesSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let state = snapshot.state
        return DebugSection(title: "Releases", rows: [
            DebugRow(label: "Running", value: describe(state.currentRelease) ?? "the embedded bundle"),
            DebugRow(label: "Downloaded", value: describe(state.nextRelease) ?? "none"),
            DebugRow(label: "Fallback", value: describe(state.fallbackRelease) ?? "the embedded bundle"),
            DebugRow(label: "Embedded bundle", value: state.embeddedBundleId ?? "not registered"),
            DebugRow(label: "Failed bundles", value: state.failedBundleIds.isEmpty ? "none" : state.failedBundleIds.joined(separator: ", "))
        ])
    }

    private static func lastCheckSection(_ snapshot: DebugSnapshot) -> DebugSection {
        guard let check = snapshot.state.lastCheck else {
            return DebugSection(title: "Last check", rows: [DebugRow(label: "When", value: "never")])
        }
        let entry = LogEntry.ofCycle(check.result, trigger: check.trigger, at: check.at)
        return DebugSection(title: "Last check", rows: [
            DebugRow(label: "When", value: Iso8601.format(check.at)),
            DebugRow(label: "Trigger", value: check.trigger.rawValue),
            DebugRow(label: "Result", value: entry.code),
            DebugRow(label: "Release", value: describe(check.result.release) ?? "none"),
            DebugRow(label: "Message", value: entry.message)
        ])
    }

    private static func indexSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let state = snapshot.state
        return DebugSection(title: "Index", rows: [
            DebugRow(label: "Sequence", value: state.index.map { String($0.sequence) } ?? "none"),
            DebugRow(label: "Fetched at", value: state.index.map { Iso8601.format($0.fetchedAt) } ?? "never"),
            DebugRow(label: "Last report at", value: state.lastReportAt.map(Iso8601.format) ?? "never")
        ])
    }

    private static func configurationSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let configuration = snapshot.configuration
        return DebugSection(title: "Configuration", rows: [
            DebugRow(label: "App id", value: configuration.appId),
            DebugRow(label: "Configured channel", value: configuration.channelId),
            DebugRow(label: "Built at", value: Iso8601.format(configuration.builtAt)),
            DebugRow(label: "Files host", value: configuration.filesBaseUrl),
            DebugRow(label: "Updates host", value: configuration.updatesBaseUrl),
            DebugRow(label: "Auto check", value: configuration.autoCheck ? "every \(Int(configuration.checkInterval)) s" : "off"),
            DebugRow(label: "Strategies", value: "download \(configuration.downloadStrategy.rawValue), install \(configuration.installStrategy.rawValue), mandatory \(configuration.mandatoryInstallStrategy.rawValue)"),
            DebugRow(label: "Ready signal", value: "\(configuration.readySignal.rawValue), \(Int(configuration.readyTimeout)) s"),
            DebugRow(label: "Debug builds", value: configuration.enabledInDebugBuilds ? "enabled" : "disabled"),
            DebugRow(label: "Public keys", value: String(configuration.publicKeys.count))
        ])
    }

    private static func logSection(_ snapshot: DebugSnapshot) -> DebugSection {
        let rows = snapshot.log.map { DebugRow(label: Iso8601.format($0.at), value: "\($0.code) — \($0.message)") }
        return DebugSection(title: "Log", rows: rows.isEmpty ? [DebugRow(label: "Entries", value: "none this session")] : rows)
    }

    private static func describe(_ release: Release?) -> String? {
        return release.map { "#\($0.number) (\($0.bundleVersion)), bundle \($0.bundleId)\($0.isMandatory ? ", mandatory" : "")" }
    }
}
