import XCTest
@testable import HotCodePushProtocol

final class DebugReportTests: XCTestCase {
    func testShouldCarryTheLastChecksCodeInTheShareText() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), conditions: [.binary(range: ">=9.0.0")])
        harness.publish([v2], sequence: 7)
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        let snapshot = await harness.core.debugSnapshot()
        let text = DebugReport.text(of: snapshot)
        let device = await harness.core.deviceResult()
        XCTAssertTrue(text.contains("Device id: \(device.id)"), text)
        XCTAssertTrue(text.contains("Result: SKIPPED INCOMPATIBLE binary"), text)
        XCTAssertTrue(text.contains("Sequence: 7"), text)
        XCTAssertTrue(text.contains("Running: the embedded bundle"), text)
        XCTAssertTrue(text.contains("SKIPPED INCOMPATIBLE binary — manual: release #1 (1.1.0) is not taken"), text)
        XCTAssertEqual(DebugReport.sections(of: snapshot).map { $0.title }, ["Device", "Channel", "Releases", "Last check", "Index", "Configuration", "Log"])
    }

    func testShouldLogTheDownloadTheInstallAndTheReportOfASync() async {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        harness.acknowledgeEvents()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        await Task.yield()
        let log = await harness.core.debugSnapshot().log
        let lifecycle = log.filter { !$0.code.hasPrefix("REPORT") }
        XCTAssertEqual(lifecycle.map { $0.code }, ["DOWNLOADED", "APPLIED", "UPDATED", "CONFIRMED"])
        XCTAssertEqual(lifecycle[0].message, "release r1: \(v2.pack.count) bytes as full pack")
        XCTAssertEqual(lifecycle[2].message, "manual: release #1 (1.1.0) installs immediate")
        XCTAssertTrue(log.contains { $0.code == "REPORTED" }, log.map { $0.code }.joined(separator: ", "))
    }

    func testShouldLogARefusedReportAndKeepTheOutbox() async {
        let harness = Harness()
        harness.http.stubJson(Fixture.eventsUrl(), ["error": "E_RATE_LIMITED"], status: 429)
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        await Task.yield()
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.last?.code, "REPORT_FAILED")
        XCTAssertEqual(log.last?.message, "2 events kept for the next sync: HTTP 429")
    }

    func testShouldKeepTheNewestTwoHundredEntries() async {
        let harness = Harness()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        for _ in 0..<(LogEntry.capacity + 5) {
            _ = await harness.core.checkForUpdate()
        }
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.count, LogEntry.capacity)
        XCTAssertEqual(log.last?.code, "UP_TO_DATE")
    }
}
