import XCTest
@testable import HotCodePushCore

// The core must hold every list of the protocol catalog, read from `node_modules`.
// A list declared alphabetically in Swift must match the catalog order; any other list must match as a set.
final class CatalogTests: XCTestCase {
    private static let catalogUrl = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("node_modules/@hotcodepush/protocol/catalog.json")

    private struct Catalog: Decodable {
        let applyStrategies: [String]
        let applyUpdateStatuses: [String]
        let channelSources: [String]
        let checkStrategies: [String]
        let conditionTypes: [String]
        let deviceEventTypes: [String]
        let downloadStrategies: [String]
        let failedReasons: [String]
        let mandatoryApplyStrategies: [String]
        let packKinds: [String]
        let platforms: [String]
        let readySignals: [String]
        let rollbackReasons: [String]
        let skippedReasons: [String]
        let syncStatuses: [String]
        let syncTriggers: [String]
    }

    private func loadCatalog() throws -> Catalog {
        return try Json.decoder.decode(Catalog.self, from: try Data(contentsOf: CatalogTests.catalogUrl))
    }

    // A list the catalog adds fails here until a field of `Catalog` and its test cover it.
    func testShouldCoverEveryListOfTheCatalog() throws {
        let lists = try Json.decoder.decode([String: [String]].self, from: try Data(contentsOf: CatalogTests.catalogUrl))
        let coveredLists = Mirror(reflecting: try loadCatalog()).children.compactMap(\.label)
        XCTAssertEqual(lists.keys.sorted(), coveredLists.sorted())
    }

    func testShouldCarryTheCatalogsApplyStrategiesInItsOrder() throws {
        XCTAssertEqual(ApplyStrategy.allCases.map(\.rawValue), try loadCatalog().applyStrategies)
    }

    func testShouldCarryTheCatalogsApplyUpdateStatusesInItsOrder() throws {
        XCTAssertEqual(ApplyUpdateStatus.allCases.map(\.rawValue), try loadCatalog().applyUpdateStatuses)
    }

    func testShouldCarryTheCatalogsChannelSources() throws {
        XCTAssertEqual(Set(ChannelSource.allCases.map(\.rawValue)), Set(try loadCatalog().channelSources))
    }

    func testShouldCarryTheCatalogsCheckStrategiesInItsOrder() throws {
        XCTAssertEqual(CheckStrategy.allCases.map(\.rawValue), try loadCatalog().checkStrategies)
    }

    func testShouldCarryTheCatalogsConditionTypes() throws {
        XCTAssertEqual(Set(ConditionType.allCases.map(\.rawValue)), Set(try loadCatalog().conditionTypes))
    }

    // The type is a string the factories write, so this lists one factory per type, alphabetically.
    func testShouldWriteTheCatalogsDeviceEventTypesInItsOrder() throws {
        let events: [DeviceEvent] = [
            .applied(releaseId: "r1"),
            .checked(releaseId: "r1", status: .available),
            .confirmed(releaseId: "r1"),
            .downloaded(releaseId: "r1", downloadSizeBytes: 4096, packKind: .full),
            .failed(releaseId: "r1", reason: FailedReason.downloadFailed.rawValue)
        ]
        XCTAssertEqual(events.map(\.type), try loadCatalog().deviceEventTypes)
    }

    func testShouldCarryTheCatalogsDownloadStrategiesInItsOrder() throws {
        XCTAssertEqual(DownloadStrategy.allCases.map(\.rawValue), try loadCatalog().downloadStrategies)
    }

    func testShouldCarryTheCatalogsFailedReasonsInItsOrder() throws {
        XCTAssertEqual(FailedReason.allCases.map(\.rawValue), try loadCatalog().failedReasons)
    }

    func testShouldCarryTheCatalogsMandatoryApplyStrategiesInItsOrder() throws {
        XCTAssertEqual(MandatoryApplyStrategy.allCases.map(\.rawValue), try loadCatalog().mandatoryApplyStrategies)
    }

    func testShouldCarryTheCatalogsPackKinds() throws {
        XCTAssertEqual(Set(PackKind.allCases.map(\.rawValue)), Set(try loadCatalog().packKinds))
    }

    func testShouldCarryTheCatalogsPlatformsInItsOrder() throws {
        XCTAssertEqual(ChannelIndex.platforms, try loadCatalog().platforms)
    }

    func testShouldCarryTheCatalogsReadySignalsInItsOrder() throws {
        XCTAssertEqual(ReadySignal.allCases.map(\.rawValue), try loadCatalog().readySignals)
    }

    func testShouldCarryTheCatalogsRollbackReasonsInItsOrder() throws {
        XCTAssertEqual(RollbackReason.allCases.map(\.rawValue), try loadCatalog().rollbackReasons)
    }

    func testShouldCarryTheCatalogsSkippedReasonsInItsOrder() throws {
        XCTAssertEqual(SkippedReason.allCases.map(\.rawValue), try loadCatalog().skippedReasons)
    }

    func testShouldCarryTheCatalogsSyncStatuses() throws {
        XCTAssertEqual(Set(SyncStatus.allCases.map(\.rawValue)), Set(try loadCatalog().syncStatuses))
    }

    func testShouldCarryTheCatalogsSyncTriggers() throws {
        XCTAssertEqual(Set(SyncTrigger.allCases.map(\.rawValue)), Set(try loadCatalog().syncTriggers))
    }
}
