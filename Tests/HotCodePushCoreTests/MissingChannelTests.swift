import XCTest
@testable import HotCodePushCore

/// A build whose build step ran without a token or offline carries no channel: it answers `UNKNOWN_CHANNEL` without a request
/// and reports nothing, until the app sets a channel at runtime.
final class MissingChannelTests: XCTestCase {
    private func harnessWithoutChannel() -> Harness {
        let harness = Harness(configuration: Fixture.configuration(channelId: nil))
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
        let result = await harness.core.sync(trigger: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result, .failed(nil, reason: .unknownChannel, message: Core.missingChannelMessage))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [])
        XCTAssertEqual(harness.listener.failed.map { $0.reason }, [.unknownChannel])
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: "", name: nil, source: .config))
    }

    func testShouldFailACheckWithUnknownChannelAndRequestNothingWhenTheBuildCarriesNoChannel() async throws {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        let result = await harness.core.checkForUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result, .failed(nil, reason: .unknownChannel, message: Core.missingChannelMessage))
        XCTAssertTrue(harness.http.requests.isEmpty)
        XCTAssertTrue(harness.http.posts.isEmpty)
    }

    func testShouldUpdateAndReportOnceAChannelIsSetAtRuntimeOnABuildWithoutOne() async throws {
        let harness = harnessWithoutChannel()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.setChannel(.id(Fixture.channelId))
        let result = await harness.core.sync(trigger: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(result.status, .updated)
        let report = try XCTUnwrap(try reports(of: harness).first)
        XCTAssertEqual(report["channelId"] as? String, Fixture.channelId)
        XCTAssertEqual(report["channelSource"] as? String, "runtime")
    }

    func testShouldAnswerUnknownChannelAgainWhenTheRuntimeChoiceIsCleared() async {
        let harness = harnessWithoutChannel()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.setChannel(.id(Fixture.channelId))
        let followed = await harness.core.sync(trigger: .manual)
        XCTAssertEqual(followed, .upToDate(nil))
        await harness.core.setChannel(nil)
        let cleared = await harness.core.sync(trigger: .manual)
        XCTAssertEqual(cleared, .failed(nil, reason: .unknownChannel, message: Core.missingChannelMessage))
    }

    func testShouldClearARuntimeChannelThatServesNoIndexAndAnswerUnknownChannel() async {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        await harness.core.setChannel(.id("c-gone"))
        let result = await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .failed(nil, reason: .unknownChannel, message: Core.missingChannelMessage))
        let channel = await harness.core.channel()
        XCTAssertEqual(channel.source, .config)
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldFallBackToTheConfiguredChannelWhenTheRuntimeChannelServesNoIndex() async {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.setChannel(.id("c-gone"))
        let result = await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .updated)
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: Fixture.channelId, name: nil, source: .config))
    }

    func testShouldSayOnTheDebugScreenThatTheBuildHasNoChannelAndWhy() async {
        let harness = harnessWithoutChannel()
        await harness.core.handleAppStart()
        _ = await harness.core.sync(trigger: .manual)
        let text = DebugReport.text(of: await harness.core.debugSnapshot())
        XCTAssertTrue(text.contains("Channel id: none: the build carries no channel, it was built without a token or offline"), text)
        XCTAssertTrue(text.contains("Configured channel: none"), text)
        XCTAssertTrue(text.contains("Result: FAILED UNKNOWN_CHANNEL"), text)
        XCTAssertTrue(text.contains(Core.missingChannelMessage), text)
    }
}
