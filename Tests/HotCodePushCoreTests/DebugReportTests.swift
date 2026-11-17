import XCTest
@testable import HotCodePushCore

final class DebugReportTests: XCTestCase {
    func testShouldCarryTheLastChecksCodeInTheShareText() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), conditions: [.binary(range: ">=9.0.0")])
        harness.publish([v2], sequence: 1_759_900_000_123)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        let snapshot = await harness.core.debugSnapshot()
        let text = DebugReport.text(of: snapshot)
        let device = await harness.core.getDevice()
        XCTAssertTrue(text.contains("Device id: \(device.id)"), text)
        XCTAssertTrue(text.contains("Result: skipped device_incompatible binary"), text)
        XCTAssertTrue(text.contains("Published at: 2025-10-08T05:06:40.123Z"), text)
        XCTAssertTrue(text.contains("Running: the embedded bundle"), text)
        XCTAssertTrue(text.contains("skipped device_incompatible binary — manual: release #1 (1.1.0) is not taken"), text)
        XCTAssertEqual(DebugReport.sections(of: snapshot).map { $0.title }, ["Device", "Channel", "Releases", "Last check", "Index", "Configuration", "Log"])
    }

    func testShouldShowTheCheckStrategyAndTheStrategiesOfTheConfiguration() async throws {
        let harness = Harness(configuration: Fixture.configuration(applyStrategy: .nextResume, mandatoryApplyStrategy: .manual, downloadStrategy: .unmetered))
        let manual = DebugReport.text(of: await harness.core.debugSnapshot())
        XCTAssertTrue(manual.contains("Check strategy: manual"), manual)
        XCTAssertTrue(manual.contains("Strategies: download unmetered, apply next_resume, mandatory manual"), manual)
        XCTAssertTrue(manual.contains("Ready signal: render, 10 s"), manual)
        XCTAssertTrue(manual.contains("Published at: none"), manual)
        XCTAssertFalse(manual.contains("host:"), manual)
        harness.restart(configuration: Fixture.configuration(checkStrategy: .auto))
        let auto = DebugReport.text(of: await harness.core.debugSnapshot())
        XCTAssertTrue(auto.contains("Check strategy: auto, every 900 s"), auto)
    }

    func testShouldLogTheDownloadTheApplyAndTheReportOfASync() async throws {
        let harness = Harness(configuration: Fixture.configuration(applyStrategy: .immediate))
        harness.acknowledgeEvents()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        await Task.yield()
        let log = await harness.core.debugSnapshot().log
        let lifecycle = log.filter { !$0.code.hasPrefix("report") }
        XCTAssertEqual(lifecycle.map { $0.code }, ["downloaded", "applied", "applied", "confirmed"])
        XCTAssertEqual(lifecycle[0].message, "release r1: \(v2.pack.count) bytes as full pack")
        XCTAssertEqual(lifecycle[2].message, "manual: release #1 (1.1.0) is applied and the app reloads")
        XCTAssertTrue(log.contains { $0.code == "reported" }, log.map { $0.code }.joined(separator: ", "))
    }

    func testShouldLogTheMomentADownloadedReleaseWaitsFor() async throws {
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        for (strategy, message) in [(ApplyStrategy.nextStart, "is downloaded and applies at next_start"), (.manual, "is downloaded and waits for applyUpdate()")] {
            let harness = Harness(configuration: Fixture.configuration(applyStrategy: strategy))
            harness.publish([v2], sequence: 1)
            await harness.core.handleAppStart()
            _ = try await harness.core.sync(trigger: .manual)
            let log = await harness.core.debugSnapshot().log
            let cycle = try XCTUnwrap(log.first { $0.message.hasPrefix("manual:") })
            XCTAssertEqual(cycle.code, "downloaded")
            XCTAssertEqual(cycle.message, "manual: release #1 (1.1.0) \(message)")
        }
    }

    func testShouldLogARateLimitedReportAndKeepTheOutbox() async throws {
        let harness = Harness()
        harness.http.stubJson(Fixture.eventsUrl(), [String: String](), status: 429)
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.last?.code, "report_failed")
        XCTAssertEqual(log.last?.message, "2 events kept for the next sync: HTTP 429")
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.count, 2)
    }

    func testShouldLogARefusedBatchWithTheCountAndTheStatus() async throws {
        let harness = Harness()
        harness.http.stubJson(Fixture.eventsUrl(), [String: String](), status: 422)
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.last?.code, "report_refused")
        XCTAssertEqual(log.last?.message, "2 events dropped: HTTP 422")
    }

    func testShouldLogAnUnreadableAcknowledgementAsAFailedReport() async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: 202, body: Data("accepted".utf8))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.last?.code, "report_failed")
        XCTAssertEqual(log.last?.message, "2 events kept for the next sync: HTTP 202")
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.count, 2)
        XCTAssertNil(StateStore(store: harness.store).reportedAt)
    }

    func testShouldKeepTheNewestTwoHundredEntries() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        for _ in 0..<(LogEntry.capacity + 5) {
            _ = try await harness.core.checkForUpdate()
        }
        await harness.core.waitForBackgroundWork()
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.count, LogEntry.capacity)
        XCTAssertEqual(log.last { $0.code != "report_failed" }?.code, "up_to_date")
    }
}
