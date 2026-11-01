import XCTest
@testable import HotCodePushCore

final class VersionRangeTests: XCTestCase {
    func testShouldNotParseAVersionOrARangeWhenAComponentIsPastTheLargestTheTypeScriptEvaluatorHolds() {
        let past = String(VersionRange.componentMaximum + 1)
        XCTAssertNil(VersionRange.parseVersion("1.\(past)"))
        XCTAssertNil(VersionRange.parseVersion("1.99999999999999999999"))
        XCTAssertNil(VersionRange.isVersionInRange([1], "<\(past)"))
        XCTAssertNil(VersionRange.isVersionInRange([1], "\(past).x"))
    }
}
