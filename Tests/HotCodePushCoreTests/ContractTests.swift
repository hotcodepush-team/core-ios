import XCTest
@testable import HotCodePushCore

/// Every result carries every key of the typed contract, `null` when empty, never an absent key.
final class ContractTests: XCTestCase {
    private func keys<T: Encodable>(_ value: T) throws -> (keys: Set<String>, object: [String: Any]) {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Json.encoder.encode(value)) as? [String: Any])
        return (Set(object.keys), object)
    }

    func testShouldCarryEveryStateKeyOnAFreshInstall() async throws {
        let harness = Harness()
        let (keys, object) = try keys(await harness.core.getState())
        XCTAssertEqual(keys, ["currentRelease", "nextRelease", "fallbackRelease", "embeddedBundleId", "lastCheck", "index", "failedBundleIds", "lastReportAt"])
        XCTAssertTrue(object["currentRelease"] is NSNull)
        XCTAssertTrue(object["lastCheck"] is NSNull)
        XCTAssertTrue(object["lastReportAt"] is NSNull)
        XCTAssertEqual(object["embeddedBundleId"] as? String, "embedded")
    }

    func testShouldCarryEveryDeviceKeyWithNullsForTheEmptyOnes() async throws {
        let harness = Harness(configuration: Fixture.configuration(fingerprint: nil, channelId: nil))
        let (keys, object) = try keys(await harness.core.deviceResult())
        XCTAssertEqual(keys, ["id", "platform", "binaryVersion", "binaryBuild", "osVersion", "sdkVersion", "fingerprint", "channel", "attributes"])
        XCTAssertTrue(object["fingerprint"] is NSNull)
        let channel = try XCTUnwrap(object["channel"] as? [String: Any])
        XCTAssertEqual(Set(channel.keys), ["id", "name", "source"])
        XCTAssertTrue(channel["id"] is NSNull)
        XCTAssertTrue(channel["name"] is NSNull)
    }

    func testShouldCarryTheKeysOfEachSyncStatus() throws {
        let release = Release(id: "r1", number: 1, bundleId: "b1", bundleVersion: "1", isMandatory: false)
        XCTAssertEqual(try keys(SyncResult.upToDate(nil)).keys, ["status", "release"])
        XCTAssertTrue(try keys(SyncResult.upToDate(nil)).object["release"] is NSNull)
        XCTAssertEqual(try keys(SyncResult.available(release, notes: nil, downloadBytes: nil)).keys, ["status", "release", "notes", "downloadBytes"])
        XCTAssertEqual(try keys(SyncResult.downloaded(release, notes: nil)).keys, ["status", "release", "notes"])
        XCTAssertEqual(try keys(SyncResult.updated(release, notes: nil, installAt: .immediate)).keys, ["status", "release", "notes", "installAt"])
        XCTAssertEqual(try keys(SyncResult.skipped(nil, reason: .channelPaused)).keys, ["status", "release", "reason"])
        XCTAssertEqual(try keys(SyncResult.skipped(release, reason: .incompatible, condition: .os)).keys, ["status", "release", "reason", "condition"])
        XCTAssertEqual(try keys(SyncResult.failed(nil, reason: .offline, message: "m")).keys, ["status", "release", "reason", "message"])
        XCTAssertEqual(try keys(NotifyReadyResult(currentRelease: nil, previousRelease: nil, isRolledBack: false, rollbackReason: nil)).keys, ["currentRelease", "previousRelease", "isRolledBack"])
        XCTAssertEqual(try keys(ApplyResult(status: .nothingToApply, release: nil)).keys, ["status", "release"])
        XCTAssertTrue(try keys(ApplyResult(status: .nothingToApply, release: nil)).object["release"] is NSNull)
        XCTAssertEqual(try keys(UpdateAvailableEvent(release: release, notes: nil, downloadBytes: nil, trigger: .manual)).keys, ["release", "notes", "downloadBytes", "trigger"])
        XCTAssertEqual(try keys(UpdateFailedEvent(release: nil, reason: .offline, message: "m", trigger: .start)).keys, ["release", "reason", "message", "trigger"])
    }
}
