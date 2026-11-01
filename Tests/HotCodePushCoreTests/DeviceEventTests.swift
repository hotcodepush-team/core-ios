import XCTest
@testable import HotCodePushCore

final class DeviceEventTests: XCTestCase {
    func testShouldRoundTripEveryEventKindThroughTheOutbox() {
        let events: [DeviceEvent] = [
            .checked(releaseId: "r2", status: .skipped, reason: .deviceIncompatible, conditionType: .binary),
            .checked(releaseId: "r3", status: .available),
            .downloaded(releaseId: "r1", downloadSizeBytes: 4096, packKind: .delta),
            .applied(releaseId: "r1"),
            .confirmed(releaseId: "r1"),
            .failed(releaseId: "r1", reason: RollbackReason.readinessTimedOut.rawValue),
            .failed(releaseId: "r1", reason: RollbackReason.appRequested.rawValue, detail: "checkout crashed on launch"),
            .failed(releaseId: "r2", reason: FailedReason.signatureInvalid.rawValue)
        ]
        let store = InMemoryStore()
        StateStore(store: store).unsentEvents = events
        XCTAssertEqual(StateStore(store: store).unsentEvents, events)
    }
}
