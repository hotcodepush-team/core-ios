import XCTest
@testable import HotCodePushCore

/// A build whose build step ran without a token or offline carries no channel: it checks nothing on its own, answers an explicit
/// call `CHANNEL_UNKNOWN` without a request and reports nothing, until the app sets a channel at runtime.
final class MissingChannelTests: XCTestCase {
    private func harnessWithoutChannel() -> Harness {
        let harness = Harness(configuration: Fixture.configuration(checkStrategy: .auto, channelId: nil))
        harness.acknowledgeEvents()
        return harness
    }

    private func reports(of harness: Harness) throws -> [[String: Any]] {
        return try harness.http.posts.compactMap { post in
            try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any])["report"] as? [String: Any]
        }
    }

    func testShouldReadAResourceFileWithANullChannelAndRefuseOneWithoutTheKey() throws {
        let resourceFile = try XCTUnwrap(JSONSerialization.jsonObject(with: try Json.encoder.encode(Fixture.embeddedManifest())) as? [String: Any])
        var json: [String: Any] = ["appId": Fixture.appId, "builtAt": Iso8601.format(Fixture.builtAt), "channelId": NSNull(), "embeddedBundleId": NSNull(), "embeddedBundleManifest": resourceFile, "fingerprint": NSNull()]
        XCTAssertNil(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)).channelId)
        json["channelId"] = ""
        XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)))
        json["channelId"] = nil
        XCTAssertThrowsError(try Configuration.decode(try JSONSerialization.data(withJSONObject: json)))
    }

    func testShouldFailASyncWithUnknownChannelAndRequestNothingWhenTheBuildCarriesNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(result, .failed(nil, reason: .channelUnknown, message: Core.missingChannelMessage))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [])
        XCTAssertEqual(harness.listener.failed.map { $0.reason }, [.channelUnknown])
        XCTAssertEqual(harness.listener.failed.map { $0.trigger }, [.manual])
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: nil, name: nil, source: .config))
    }

    func testShouldFailACheckWithUnknownChannelAndRequestNothingWhenTheBuildCarriesNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        let result = try await harness.core.checkForUpdate()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(result, .failed(nil, reason: .channelUnknown, message: Core.missingChannelMessage))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
        XCTAssertEqual(harness.listener.failed.map { $0.reason }, [.channelUnknown])
        XCTAssertEqual(harness.listener.failed.map { $0.trigger }, [.manual])
    }

    func testShouldSkipAnExplicitSyncWithDebugBuildWhenTheBuildIsDisabledAndTheDeviceHasNoChannel() async throws {
        let harness = Harness(configuration: Fixture.configuration(enabledInDebugBuilds: false, channelId: nil), isDebugBuild: true)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .skipped(nil, reason: .buildDebug))
        XCTAssertTrue(harness.listener.failed.isEmpty)
    }

    func testShouldStartNoCheckAtStartWhenTheDeviceHasNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        try await assertNoCheckStarted(harness)
    }

    func testShouldStartNoCheckAtTheConfirmationOfANewReleaseWhenTheDeviceHasNoChannel() async throws {
        let harness = harnessWithoutChannel()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.channelId))
        _ = try await harness.core.sync(trigger: .manual)
        try await harness.core.setChannel(nil)
        await harness.core.waitForBackgroundWork()
        let requestCount = harness.http.requests.count
        harness.loader.served = "b2"
        harness.restart(configuration: Fixture.configuration(checkStrategy: .auto, channelId: nil))
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertEqual(started.currentRelease, v2.release.release)
        _ = await harness.core.notifyReady()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .manual)
        XCTAssertEqual(harness.http.requests.count, requestCount)
        XCTAssertTrue(harness.listener.failed.isEmpty)
    }

    func testShouldStartNoCheckOnResumeWhenTheDeviceHasNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        await harness.core.handleAppPause()
        harness.clock.now = harness.clock.now.addingTimeInterval(1000)
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        try await assertNoCheckStarted(harness)
    }

    func testShouldStartNoCheckAndArmNoTimerWhenTheIntervalFiresAndTheDeviceHasNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [900])
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .manual)
        XCTAssertEqual(harness.listener.failed.map { $0.trigger }, [.manual])
        XCTAssertTrue(harness.scheduler.tasks.isEmpty)
        XCTAssertTrue(harness.http.requests.isEmpty)
    }

    func testShouldCheckOnItsOwnAgainAtTheNextResumeWhenAChannelWasSetAtRuntime() async throws {
        let harness = harnessWithoutChannel()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.channelId))
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        let lastCheck = try XCTUnwrap(StateStore(store: harness.store).lastCheck)
        XCTAssertEqual(lastCheck.trigger, .resume)
        XCTAssertEqual(lastCheck.result, .upToDate(nil))
    }

    func testShouldFireUpdateFailedOnceWhenAnAutomaticCheckFindsItsRuntimeChannelGoneAndTheBuildCarriesNoneAndStartNoCheckAfterIt() async throws {
        let harness = harnessWithoutChannel()
        try await harness.core.setChannel(.id(Fixture.goneChannelId))
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.listener.failed.map { $0.reason }, [.channelUnknown])
        XCTAssertEqual(harness.listener.failed.map { $0.trigger }, [.start])
        await harness.scheduler.fire()
        await harness.core.handleAppPause()
        harness.clock.now = harness.clock.now.addingTimeInterval(1000)
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.listener.failed.count, 1)
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldUpdateAndReportOnceAChannelIsSetAtRuntimeOnABuildWithoutOne() async throws {
        let harness = harnessWithoutChannel()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.channelId))
        let result = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(result.status, .downloaded)
        let report = try XCTUnwrap(try reports(of: harness).first)
        XCTAssertEqual(report["channelId"] as? String, Fixture.channelId)
        XCTAssertEqual(report["channelSource"] as? String, "runtime")
    }

    func testShouldAnswerUnknownChannelAgainWhenTheRuntimeChoiceIsCleared() async throws {
        let harness = harnessWithoutChannel()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.channelId))
        let followed = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(followed, .upToDate(nil))
        try await harness.core.setChannel(nil)
        let cleared = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(cleared, .failed(nil, reason: .channelUnknown, message: Core.missingChannelMessage))
    }

    func testShouldClearARuntimeChannelThatServesNoIndexAndAnswerUnknownChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.goneChannelId))
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .failed(nil, reason: .channelUnknown, message: Core.missingChannelMessage))
        let channel = await harness.core.channel()
        XCTAssertEqual(channel.source, .config)
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldFallBackToTheConfiguredChannelWhenTheRuntimeChannelServesNoIndex() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        try await harness.core.setChannel(.id(Fixture.goneChannelId))
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .downloaded)
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: Fixture.channelId, name: nil, source: .config))
    }

    /// A cycle that is not started leaves no trace: no check, no log entry, no event, no request and no interval timer.
    private func assertNoCheckStarted(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertNil(StateStore(store: harness.store).lastCheck, file: file, line: line)
        XCTAssertNil(StateStore(store: harness.store).lastSyncAt, file: file, line: line)
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log, [], file: file, line: line)
        XCTAssertTrue(harness.listener.failed.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.http.requests.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.http.posts.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.scheduler.tasks.isEmpty, file: file, line: line)
    }

    func testShouldSayOnTheDebugScreenThatTheBuildHasNoChannelAndWhy() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        let text = DebugReport.text(of: await harness.core.debugSnapshot())
        XCTAssertTrue(text.contains("Channel id: none: the build carries no channel, it was built without a token or offline"), text)
        XCTAssertTrue(text.contains("Configured channel: none"), text)
        XCTAssertTrue(text.contains("Result: FAILED CHANNEL_UNKNOWN"), text)
        XCTAssertTrue(text.contains(Core.missingChannelMessage), text)
    }
}
