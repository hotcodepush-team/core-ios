import XCTest
@testable import HotCodePushCore

final class DeviceEventTests: XCTestCase {
    // The batch of the schema test in `@hotcodepush/protocol`, plus a check that found a release.
    // `DeviceEventsRequestSchema` accepts it as it stands, but refuses it without a nullable report key.
    // It also refuses a `null` on the optional `reason`, `conditionType` or `detail`.
    private static let batch = """
    {
      "deviceId": "d1",
      "events": [
        { "conditionType": "binary", "reason": "device_incompatible", "releaseId": "r2", "status": "skipped", "type": "checked" },
        { "releaseId": "r3", "status": "available", "type": "checked" },
        { "downloadSizeBytes": 4096, "packKind": "delta", "releaseId": "r1", "type": "downloaded" },
        { "releaseId": "r1", "type": "applied" },
        { "releaseId": "r1", "type": "confirmed" },
        { "reason": "readiness_timed_out", "releaseId": "r1", "type": "failed" },
        { "detail": "checkout crashed on launch", "reason": "app_requested", "releaseId": "r1", "type": "failed" },
        { "reason": "signature_invalid", "releaseId": "r2", "type": "failed" }
      ],
      "platform": "ios",
      "report": {
        "attributes": {},
        "binaryBuild": "57",
        "binaryVersion": "2.4.1",
        "channelId": "c1",
        "channelSource": "config",
        "embeddedBundleId": null,
        "fingerprint": null,
        "osVersion": "17.4",
        "releaseId": null
      },
      "sdkVersion": "0.0.0"
    }
    """

    private static let events: [DeviceEvent] = [
        .checked(releaseId: "r2", status: .skipped, reason: .deviceIncompatible, conditionType: .binary),
        .checked(releaseId: "r3", status: .available),
        .downloaded(releaseId: "r1", downloadSizeBytes: 4096, packKind: .delta),
        .applied(releaseId: "r1"),
        .confirmed(releaseId: "r1"),
        .failed(releaseId: "r1", reason: RollbackReason.readinessTimedOut.rawValue),
        .failed(releaseId: "r1", reason: RollbackReason.appRequested.rawValue, detail: "checkout crashed on launch"),
        .failed(releaseId: "r2", reason: FailedReason.signatureInvalid.rawValue)
    ]

    private static let report = DeviceReport(attributes: [:], binaryBuild: "57", binaryVersion: "2.4.1", channelId: "c1", channelSource: .config, embeddedBundleId: nil, fingerprint: nil, osVersion: "17.4", releaseId: nil)

    private func jsonObject<T: Encodable>(_ value: T) throws -> NSObject {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try Json.encoder.encode(value)) as? NSObject)
    }

    private func batchObject() throws -> NSDictionary {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DeviceEventTests.batch.utf8)) as? NSDictionary)
    }

    func testShouldEncodeABatchOfEveryEventKindAsTheSchemaReadsIt() throws {
        let request = DeviceEventsRequest(deviceId: "d1", events: DeviceEventTests.events, platform: "ios", report: DeviceEventTests.report, sdkVersion: "0.0.0")
        XCTAssertEqual(try jsonObject(request), try batchObject())
    }

    func testShouldRoundTripEveryEventKindThroughTheOutbox() throws {
        let documents = try XCTUnwrap(try batchObject()["events"] as? [NSDictionary])
        XCTAssertEqual(documents.count, DeviceEventTests.events.count)
        for (document, expected) in zip(documents, DeviceEventTests.events) {
            let event = try Json.decoder.decode(DeviceEvent.self, from: try JSONSerialization.data(withJSONObject: document))
            XCTAssertEqual(event, expected, "\(document)")
            XCTAssertEqual(try jsonObject(event), document, "\(document)")
        }
        let state = StateStore(store: InMemoryStore())
        state.unsentEvents = DeviceEventTests.events
        XCTAssertEqual(state.unsentEvents, DeviceEventTests.events)
    }

    func testShouldLeaveAnOptionalFieldOutWhenItIsEmpty() throws {
        let checked = try XCTUnwrap(try jsonObject(DeviceEvent.checked(releaseId: "r3", status: .available)) as? [String: Any])
        XCTAssertEqual(Set(checked.keys), ["releaseId", "status", "type"])
        let failed = try XCTUnwrap(try jsonObject(DeviceEvent.failed(releaseId: "r1", reason: FailedReason.downloadFailed.rawValue)) as? [String: Any])
        XCTAssertEqual(Set(failed.keys), ["reason", "releaseId", "type"])
    }

    func testShouldWriteEveryNullableFactOfTheReportAndAnAbsentReportAsNull() throws {
        let report = try XCTUnwrap(try jsonObject(DeviceEventTests.report) as? [String: Any])
        for key in ["embeddedBundleId", "fingerprint", "releaseId"] {
            XCTAssertTrue(report[key] is NSNull, key)
        }
        let request = try XCTUnwrap(try jsonObject(DeviceEventsRequest(deviceId: "d1", events: [], platform: "ios", report: nil, sdkVersion: "0.0.0")) as? [String: Any])
        XCTAssertTrue(request["report"] is NSNull)
    }
}
