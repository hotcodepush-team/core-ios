import XCTest
@testable import HotCodePushCore

/// A build whose build step found no JavaScript bundled embeds no bundle: live updates are off in it, every cycle skips with
/// `DEBUG_BUILD` without a request, and nothing is sent.
final class MissingEmbeddedBundleTests: XCTestCase {
    private func configurationWithoutEmbeddedBundle(channelId: String? = Fixture.channelId, installStrategy: InstallStrategy = .nextStart) -> Configuration {
        return Fixture.configuration(installStrategy: installStrategy, builtAt: Fixture.builtAt.addingTimeInterval(86_400), channelId: channelId, hasEmbeddedBundle: false)
    }

    /// A debug build served by the development server, with debug builds enabled as the project leaves them, and a release on its channel.
    private func harnessWithoutEmbeddedBundle() -> Harness {
        let harness = Harness(configuration: configurationWithoutEmbeddedBundle(), isDebugBuild: true)
        harness.acknowledgeEvents()
        harness.publish([Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))], sequence: 1)
        return harness
    }

    func testShouldReadAResourceFileWithANullEmbeddedBundleManifestAndRefuseOneWithoutTheKey() throws {
        var json: [String: Any] = ["appId": Fixture.appId, "builtAt": Iso8601.format(Fixture.builtAt), "channelId": NSNull(), "embeddedBundleId": NSNull(), "embeddedBundleManifest": NSNull(), "fingerprint": "fp1:abc"]
        XCTAssertNil(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)).embeddedBundleManifest)
        json["embeddedBundleManifest"] = nil
        XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)))
    }

    func testShouldSkipASyncWithDebugBuildAndRequestNothingWhenTheBuildEmbedsNoBundle() async throws {
        let harness = harnessWithoutEmbeddedBundle()
        await harness.core.handleAppStart()
        let result = await harness.core.sync(trigger: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result, .skipped(nil, reason: .debugBuild))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
    }

    func testShouldSkipACheckWithDebugBuildAndRequestNothingWhenTheBuildEmbedsNoBundle() async throws {
        let harness = harnessWithoutEmbeddedBundle()
        await harness.core.handleAppStart()
        let result = await harness.core.checkForUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result, .skipped(nil, reason: .debugBuild))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
    }

    func testShouldSkipADownloadWithDebugBuildAndRequestNothingWhenTheBuildEmbedsNoBundle() async throws {
        let harness = harnessWithoutEmbeddedBundle()
        await harness.core.handleAppStart()
        let result = await harness.core.downloadUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result, .skipped(nil, reason: .debugBuild))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
    }

    func testShouldSkipWithDebugBuildWhenTheBuildEmbedsNoBundleIsNoDebugBuildAndHasDebugBuildsEnabled() async {
        let harness = Harness(configuration: configurationWithoutEmbeddedBundle(), isDebugBuild: false)
        harness.publish([Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))], sequence: 1)
        await harness.core.handleAppStart()
        let result = await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .skipped(nil, reason: .debugBuild))
        XCTAssertTrue(harness.http.requests.isEmpty)
    }

    func testShouldEmptyTheStoreAndAnnounceNothingAtTheStartOfABuildWithoutAnEmbeddedBundleWhenTheStoreHoldsAnotherBinarysReleases() async {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        let v4 = Fixture.release(number: 3, bundleId: "b4", content: Data("<html>v4</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        _ = await harness.core.sync(trigger: .manual)
        harness.publish([v2, v3, v4], sequence: 3, etag: "\"e3\"")
        _ = await harness.core.sync(trigger: .manual, options: SyncOptions(installStrategy: .nextStart))
        let held = await harness.core.getState()
        XCTAssertEqual([held.currentRelease?.id, held.nextRelease?.id, held.fallbackRelease?.id], ["r2", "r3", "r1"])
        let outbox = StateStore(store: harness.store).unsentEvents
        let timerCount = harness.scheduler.tasks.count
        harness.loader.served = "b4"
        harness.restart(configuration: configurationWithoutEmbeddedBundle())
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertNil(started.currentRelease)
        XCTAssertNil(started.nextRelease)
        XCTAssertNil(started.fallbackRelease)
        XCTAssertEqual(started.failedBundleIds, [])
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
        XCTAssertEqual(harness.scheduler.tasks.count, timerCount)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, outbox)
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        XCTAssertEqual(harness.loader.loaded.last, .some(nil))
    }

    func testShouldSendNoBatchWhenTheBuildEmbedsNoBundleAndTheOutboxHoldsEvents() async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: 500, body: Data())
        harness.publish([Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))], sequence: 1)
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        let outbox = StateStore(store: harness.store).unsentEvents
        XCTAssertEqual(outbox.count, 2)
        let postCount = harness.http.posts.count
        harness.acknowledgeEvents()
        harness.restart(configuration: configurationWithoutEmbeddedBundle())
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.http.posts.count, postCount)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, outbox)
    }

    func testShouldAnswerNothingToApplyAndNoRollbackWhenTheBuildEmbedsNoBundle() async throws {
        let harness = harnessWithoutEmbeddedBundle()
        await harness.core.handleAppStart()
        let applied = await harness.core.applyUpdate()
        XCTAssertEqual(applied, ApplyResult(status: .nothingToApply, release: nil))
        let ready = await harness.core.notifyReady()
        XCTAssertEqual(ready, NotifyReadyResult(currentRelease: nil, previousRelease: nil, isRolledBack: false, rollbackReason: nil))
        try await harness.core.rollbackUpdate(detail: nil)
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
    }

    func testShouldSayOnTheDebugReportThatTheBuildEmbedsNoBundle() async {
        let harness = Harness(configuration: configurationWithoutEmbeddedBundle(channelId: nil), isDebugBuild: true)
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        let text = DebugReport.text(of: await harness.core.debugSnapshot())
        XCTAssertTrue(text.contains("Embedded bundle: none: the build embeds no bundle, live updates are off in it"), text)
        XCTAssertTrue(text.contains("Result: SKIPPED DEBUG_BUILD"), text)
    }
}
