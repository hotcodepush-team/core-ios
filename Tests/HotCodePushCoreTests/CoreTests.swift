import XCTest
@testable import HotCodePushCore

final class CoreTests: XCTestCase {
    func testShouldRunTheEmbeddedBundleAndBeUpToDateOnAnEmptyChannel() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .upToDate(nil))
        XCTAssertTrue(harness.listener.available.isEmpty)
        XCTAssertTrue(harness.listener.failed.isEmpty)
    }

    func testShouldDownloadAReleaseAndApplyItAtTheNextStart() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .updated(v2.release.release, notes: "notes 1", installAt: .nextStart))
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertEqual(try Data(contentsOf: harness.loader.projectionDirectory(bundleId: "b2").appendingPathComponent("index.html")), Data("<html>v2</html>".utf8))
        let status = await harness.core.getState()
        XCTAssertEqual(status.nextRelease, v2.release.release)
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.index?.sequence, 1)

        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertEqual(started.currentRelease, v2.release.release)
        XCTAssertNil(started.nextRelease)
        XCTAssertNil(started.fallbackRelease)
        XCTAssertEqual(harness.scheduler.tasks.count, 1)
        let ready = await harness.core.notifyReady()
        XCTAssertEqual(ready, NotifyReadyResult(currentRelease: v2.release.release, previousRelease: nil, isRolledBack: false, rollbackReason: nil))
        let confirmed = await harness.core.getState()
        XCTAssertEqual(confirmed.fallbackRelease, v2.release.release)
        XCTAssertTrue(harness.scheduler.tasks[0].isCancelled)
    }

    func testShouldNameTheReleaseASwitchReplacedAsPreviousReleaseOnce() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        _ = await harness.core.notifyReady()
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b3"
        harness.restart()
        await harness.core.handleAppStart()
        let ready = await harness.core.notifyReady()
        XCTAssertEqual(ready, NotifyReadyResult(currentRelease: v3.release.release, previousRelease: v2.release.release, isRolledBack: false, rollbackReason: nil))
        let again = await harness.core.notifyReady()
        XCTAssertNil(again.previousRelease)
    }

    func testShouldAnswerTheBundleTheHostServesAtStart() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        let embedded = await harness.core.handleAppStart()
        XCTAssertNil(embedded)
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let switched = await harness.core.handleAppStart()
        XCTAssertEqual(switched, "b2")
    }

    func testShouldAnswerTheStartsBundleToAHostThatWaitsInSynchronousCode() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let core = harness.core
        let answer = await Task.detached { core.handleAppStartBlocking() }.value
        XCTAssertEqual(answer, "b2")
    }

    func testShouldAnswerTheEmbeddedBundleWhenTheStartDoesNotAnswerInTimeAndReloadIntoItsBundleOnceItDoes() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let release = DispatchSemaphore(value: 0)
        harness.loader.whileReadingServedBundle = { _ = release.wait(timeout: .now() + 5) }
        let core = harness.core
        let answer = await Task.detached { core.handleAppStartBlocking(timeout: 0.1) }.value
        XCTAssertNil(answer)
        release.signal()
        await harness.core.waitForBackgroundWork()
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.bundleId, "b2")
        XCTAssertEqual(harness.loader.loaded, ["b2"])
    }

    func testShouldHoldARestartUntilTheReloadedBundleRendersWhenAStartThatAnsweredTooLateReloadsAfterARender() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let core = harness.core
        await core.handleRendered()
        let release = DispatchSemaphore(value: 0)
        harness.loader.whileReadingServedBundle = { _ = release.wait(timeout: .now() + 5) }
        let answer = await Task.detached { core.handleAppStartBlocking(timeout: 0.1) }.value
        XCTAssertNil(answer)
        release.signal()
        await core.waitForBackgroundWork()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await core.clearUpdates()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
    }

    func testShouldNeitherApplyAWaitingReleaseNorArmTheGateAtAHeadlessStart() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        let headless = await harness.core.handleAppStart(isHeadless: true)
        XCTAssertNil(headless)
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.nextRelease?.id, "r1")
        XCTAssertTrue(harness.scheduler.tasks.isEmpty)
        harness.restart()
        let started = await harness.core.handleAppStart()
        XCTAssertEqual(started, "b2")
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [10])
    }

    func testShouldConfirmTheReleaseAtTheRenderOfTheReloadedBundleNotOfTheEmbeddedOneWhenTheStartAnsweredTooLate() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let core = harness.core
        let release = DispatchSemaphore(value: 0)
        harness.loader.whileReadingServedBundle = { _ = release.wait(timeout: .now() + 5) }
        let answer = await Task.detached { core.handleAppStartBlocking(timeout: 0.1) }.value
        XCTAssertNil(answer)
        let bundleLoadCountAtEmbeddedRender = core.bundleLoadCount.value
        release.signal()
        await core.handleRendered(bundleLoadCountAtSignal: bundleLoadCountAtEmbeddedRender)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let embeddedRendered = await core.getState()
        XCTAssertNil(embeddedRendered.fallbackRelease)
        await core.handleRendered()
        let reloadedRendered = await core.getState()
        XCTAssertEqual(reloadedRendered.fallbackRelease, v2.release.release)
    }

    func testShouldConfirmNothingAtANotifyReadyOfTheEmbeddedBundleWhenTheStartAnsweredTooLate() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let core = harness.core
        let release = DispatchSemaphore(value: 0)
        harness.loader.whileReadingServedBundle = { _ = release.wait(timeout: .now() + 5) }
        let answer = await Task.detached { core.handleAppStartBlocking(timeout: 0.1) }.value
        XCTAssertNil(answer)
        let bundleLoadCountAtEmbeddedReady = core.bundleLoadCount.value
        release.signal()
        let ready = await core.notifyReady(bundleLoadCountAtSignal: bundleLoadCountAtEmbeddedReady)
        XCTAssertEqual(ready, NotifyReadyResult(currentRelease: v2.release.release, previousRelease: nil, isRolledBack: false, rollbackReason: nil))
        let status = await core.getState()
        XCTAssertNil(status.fallbackRelease)
    }

    func testShouldKeepAHeldInstallForTheNextStartAcrossAHeadlessStart() async throws {
        let configuration = Fixture.configuration(installStrategy: .immediate)
        let harness = Harness(configuration: configuration)
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        harness.loader.served = harness.loader.persisted ?? nil
        harness.restart(configuration: configuration)
        let headless = await harness.core.handleAppStart(isHeadless: true)
        XCTAssertNil(headless)
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        XCTAssertEqual(harness.loader.loaded, [])
        harness.loader.served = harness.loader.persisted ?? nil
        harness.restart(configuration: configuration)
        let started = await harness.core.handleAppStart()
        XCTAssertEqual(started, "b2")
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.id, "r1")
        XCTAssertNil(status.nextRelease)
    }

    func testShouldStillRollBackACrashAtAHeadlessStart() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        harness.scheduler.tasks = []
        harness.restart()
        let headless = await harness.core.handleAppStart(isHeadless: true)
        XCTAssertNil(headless)
        XCTAssertEqual(StateStore(store: harness.store).failedBundleIds, ["b2"])
        XCTAssertTrue(harness.scheduler.tasks.isEmpty)
    }

    func testShouldApplyAHeldInstallAndGateItWhenTheHostReloadsOnItsOwn() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        harness.loader.served = "b2"
        let reloaded = await harness.core.handleAppReload()
        XCTAssertEqual(reloaded, "b2")
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.id, "r1")
        XCTAssertNil(status.nextRelease)
        XCTAssertEqual(harness.scheduler.tasks.filter { !$0.isCancelled }.map { $0.seconds }, [10])
        XCTAssertEqual(harness.loader.loaded, [])
        await harness.scheduler.fire()
        let timedOut = await harness.core.getState()
        XCTAssertNil(timedOut.currentRelease)
        XCTAssertEqual(StateStore(store: harness.store).failedBundleIds, ["b2"])
    }

    func testShouldTakeNoUnconfirmedReleaseForACrashWhenTheHostReloadsOnItsOwn() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        let reloaded = await harness.core.handleAppReload()
        XCTAssertEqual(reloaded, "b2")
        XCTAssertTrue(StateStore(store: harness.store).failedBundleIds.isEmpty)
        await harness.core.handleRendered()
        let status = await harness.core.getState()
        XCTAssertEqual(status.fallbackRelease?.id, "r1")
    }

    func testShouldDropAHeldInstallWhoseReleaseWasRevokedWhileItWaited() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        harness.publish([v2], sequence: 2, revoked: ["r1"], etag: "\"e2\"")
        _ = try await harness.core.checkForUpdate()
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.nextRelease)
    }

    func testShouldDropAHeldApplyUpdateWhoseReleaseWasRevokedWhileItWaited() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        let applied = await harness.core.applyUpdate()
        XCTAssertEqual(applied.status, .applied)
        harness.publish([v2], sequence: 2, revoked: ["r1"], etag: "\"e2\"")
        _ = try await harness.core.checkForUpdate()
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, [])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.nextRelease)
    }

    func testShouldAnswerTheEmbeddedBundleAtAStartOverAStoreItCannotRead() async {
        for stored in ["{ not json", #"{"id":"r1"}"#] {
            let harness = Harness()
            harness.store.set(stored, forKey: "hotcodepush.currentRelease")
            harness.store.set(stored, forKey: "hotcodepush.fallbackRelease")
            let answer = await harness.core.handleAppStart()
            XCTAssertNil(answer, stored)
            let status = await harness.core.getState()
            XCTAssertNil(status.currentRelease, stored)
            XCTAssertNil(status.fallbackRelease, stored)
            XCTAssertTrue(harness.listener.rolledBack.isEmpty, stored)
        }
    }

    func testShouldStartOnTheEmbeddedBundleWhenTheBinaryChanged() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        StateStore(store: harness.store).failedBundleIds = ["b0"]
        harness.loader.served = nil
        harness.restart(configuration: Fixture.configuration(builtAt: Fixture.builtAt.addingTimeInterval(86_400)))
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.nextRelease)
        XCTAssertNil(status.fallbackRelease)
        XCTAssertEqual(status.failedBundleIds, [])
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertEqual(harness.files.bundleIds(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.loader.projectionDirectory(bundleId: "b2").path))
    }

    func testShouldKeepTheCurrentReleaseWhenTheBinaryIsTheSame() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.restart()
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease, v2.release.release)
        XCTAssertEqual(status.fallbackRelease, v2.release.release)
        XCTAssertEqual(harness.files.bundleIds(), ["b2"])
    }

    func testShouldStartOnTheEmbeddedBundleWhenTheCurrentReleaseHasNoFilesOnDisk() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.files.deleteEverything()
        harness.loader.deleteProjection(bundleId: "b2")
        harness.restart()
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.fallbackRelease)
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
    }

    func testShouldStartOnTheEmbeddedBundleWhenTheNextReleaseHasNoFilesOnDisk() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.files.deleteEverything()
        harness.loader.deleteProjection(bundleId: "b2")
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.nextRelease)
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        XCTAssertEqual(harness.loader.loaded, [nil])
    }

    func testShouldRollBackAReleaseThatNeverRendersAndBlocklistIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .immediate)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertEqual(harness.scheduler.tasks.count, 1)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, ["b2"])
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        let again = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(again, .skipped(v2.release.release, reason: .bundleFailedBefore))
        let ready = await harness.core.notifyReady()
        XCTAssertEqual(ready.isRolledBack, true)
        XCTAssertEqual(ready.rollbackReason, .readinessTimedOut)
        XCTAssertEqual(ready.previousRelease, v2.release.release)
    }

    func testShouldTreatAStartOnAnUnconfirmedReleaseAsACrash() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        harness.restart()
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, ["b2"])
        XCTAssertEqual(harness.listener.rolledBack.last?.reason, .appCrashed)
        XCTAssertEqual(harness.loader.loaded.last, .some(nil))
    }

    func testShouldFallBackToTheLastConfirmedReleaseNotTheEmbeddedBundle() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        try? await harness.core.rollbackUpdate(detail: "fatal")
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease, v2.release.release)
        XCTAssertEqual(status.failedBundleIds, ["b3"])
        XCTAssertEqual(harness.loader.loaded.last, "b2")
        let events = StateStore(store: harness.store).unsentEvents
        XCTAssertEqual(events.last?.type, "rolledBack")
        XCTAssertEqual(events.last?.toReleaseId, "r1")
    }

    func testShouldKeepTheCachedIndexOfflineAndIgnoreAnOlderSequence() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 5)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.http.isOffline = true
        let offline = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(offline.status, .updated)
        harness.http.isOffline = false
        harness.publish([], sequence: 4, etag: "\"e0\"")
        let stale = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(stale.status, .updated)
        let status = await harness.core.getState()
        XCTAssertEqual(status.index?.sequence, 5)
    }

    func testShouldIgnoreAnOlderSequenceWhenTheKeptIndexIsYoungerThanADay() async throws {
        let harness = Harness()
        harness.publish([], sequence: 5)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.clock.now = harness.clock.now.addingTimeInterval(23 * 3600)
        harness.publish([], sequence: 4, etag: "\"e0\"")
        _ = try await harness.core.sync(trigger: .manual)
        let status = await harness.core.getState()
        XCTAssertEqual(status.index?.sequence, 5)
    }

    func testShouldTakeAnOlderSequenceWhenTheKeptIndexIsOlderThanADay() async throws {
        let harness = Harness()
        harness.publish([], sequence: 5)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.clock.now = harness.clock.now.addingTimeInterval(25 * 3600)
        harness.publish([], sequence: 4, etag: "\"e0\"")
        _ = try await harness.core.sync(trigger: .manual)
        let status = await harness.core.getState()
        XCTAssertEqual(status.index?.sequence, 4)
    }

    func testShouldTakeTheFetchedIndexWhenTheBinaryChangedUnderAFarFutureSequence() async throws {
        let harness = Harness()
        harness.publish([], sequence: 9_999_999_999_999, etag: "\"e9\"")
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.publish([], sequence: 1_759_900_000_000, etag: "\"e1\"")
        let requestCountBeforeRestart = harness.http.requests.count
        harness.restart(configuration: Fixture.configuration(builtAt: Fixture.builtAt.addingTimeInterval(86_400)))
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        let status = await harness.core.getState()
        XCTAssertEqual(status.index?.sequence, 1_759_900_000_000)
        XCTAssertNil(harness.http.requests[requestCountBeforeRestart].headers["If-None-Match"])
    }

    func testShouldKeepAMillisecondSequenceThroughTheStoreAndCompareIt() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1_759_900_000_000)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.restart()
        let restored = await harness.core.getState()
        XCTAssertEqual(restored.index?.sequence, 1_759_900_000_000)
        harness.publish([], sequence: 1_759_900_000_001, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        harness.publish([], sequence: 1_759_900_000_000, etag: "\"e1\"")
        _ = try await harness.core.sync(trigger: .manual)
        let status = await harness.core.getState()
        XCTAssertEqual(status.index?.sequence, 1_759_900_000_001)
    }

    func testShouldFailOfflineWithoutACachedIndex() async throws {
        let harness = Harness()
        harness.http.isOffline = true
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.reason, FailedReason.deviceOffline.rawValue)
    }

    func testShouldSendTheEtagAndAcceptANotModified() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1, etag: "\"e1\"")
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.http.stub(Fixture.indexUrl(), status: 304, body: Data())
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .upToDate(nil))
        XCTAssertEqual(harness.http.requests.last?.headers["If-None-Match"], "\"e1\"")
    }

    func testShouldCheckWithoutDownloading() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.checkForUpdate()
        XCTAssertEqual(result, .available(v2.release.release, notes: "notes 1", downloadBytes: 15))
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertEqual(harness.listener.available.map { $0.release }, [v2.release.release])
        XCTAssertEqual(harness.listener.available.first?.trigger, .manual)
    }

    func testShouldRefuseATamperedManifest() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        harness.http.stubJson(v2.release.manifestUrl, ManifestEnvelope(bundleId: "b2", createdAt: v2.envelope.createdAt, manifest: v2.envelope.manifest + " ", pack: v2.envelope.pack))
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.reason, FailedReason.manifestInvalid.rawValue)
    }

    func testShouldRefuseAnUnsignedManifestOnceAPublicKeyIsConfigured() async throws {
        let harness = Harness(configuration: Fixture.configuration(publicKeys: [SigningFixture.publicKey(of: SigningFixture.keyA)]))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.reason, FailedReason.signatureInvalid.rawValue)
    }

    func testShouldAdoptAReleaseCarryingTheRunningBundleWithoutAReload() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        let rollback = Fixture.release(number: 2, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2, rollback], sequence: 2, etag: "\"e2\"")
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .updated(rollback.release.release, notes: "notes 2", installAt: .immediate))
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.id, "r2")
        XCTAssertEqual(status.fallbackRelease?.id, "r2")
    }

    func testShouldAnswerUpToDateNotUpdatedWhenADownloadAdoptsAReleaseCarryingTheRunningBundle() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        let rollback = Fixture.release(number: 2, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2, rollback], sequence: 2, etag: "\"e2\"")
        let result = try await harness.core.downloadUpdate()
        XCTAssertEqual(result, .upToDate(rollback.release.release))
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.id, "r2")
        XCTAssertEqual(harness.loader.loaded, ["b2"])
    }

    func testShouldRevertToTheEmbeddedBundleWhenTheRunningReleaseIsRevoked() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.publish([v2], sequence: 2, revoked: ["r1"], etag: "\"e2\"")
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .skipped(nil, reason: .releaseRevoked))
        XCTAssertEqual(harness.loader.loaded.last, .some(nil))
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
    }

    func testShouldQueueTheSwitchWithTheReloadWhileRestartsAreNotAllowed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .immediate)
        XCTAssertEqual(harness.loader.loaded, [])
        let queued = await harness.core.getState()
        XCTAssertNil(queued.currentRelease)
        XCTAssertEqual(queued.nextRelease, v2.release.release)
        XCTAssertEqual(harness.scheduler.tasks.count, 0)
        XCTAssertFalse(StateStore(store: harness.store).unsentEvents.contains { $0.type == "applied" })
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
        XCTAssertNil(installed.nextRelease)
        XCTAssertEqual(harness.scheduler.tasks.count, 1)
    }

    func testShouldApplyUpdateAtOnceWhileRestartsAreNotAllowed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .manual)
        _ = await harness.core.applyUpdate()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease, v2.release.release)
        XCTAssertNil(status.nextRelease)
    }

    func testShouldReportARollbackToTheEmbeddedBundleWithANullRelease() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        harness.acknowledgeEvents()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let events = try harness.http.posts.flatMap { post in
            try XCTUnwrap((try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any]))["events"] as? [[String: Any]])
        }
        let rolledBack = try XCTUnwrap(events.first { $0["type"] as? String == "rolledBack" })
        XCTAssertEqual(rolledBack["fromReleaseId"] as? String, "r1")
        XCTAssertTrue(rolledBack["toReleaseId"] is NSNull)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [])
    }

    func testShouldRollBackAtOnceWhileRestartsAreNotAllowed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        await harness.core.setRestartAllowed(false)
        try? await harness.core.rollbackUpdate(detail: "fatal")
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, ["b2"])
    }

    func testShouldClearUpdatesAtOnceWhileRestartsAreNotAllowed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        await harness.core.clearUpdates()
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(harness.files.bundleIds(), [])
    }

    func testShouldInstallANextResumeReleaseAfterInstallOnResumeAfter() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextResume))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .nextResume)
        await harness.core.handleAppPause()
        harness.clock.now = harness.clock.now.addingTimeInterval(300)
        await harness.core.handleAppResume()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease, v2.release.release)
        XCTAssertNil(status.nextRelease)
        XCTAssertEqual(harness.scheduler.tasks.count, 1)
    }

    func testShouldNeverInstallOnResumeAMandatoryReleaseTheAppTookOverWhenTheStrategyIsNextResume() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextResume, mandatoryInstallStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .manual)
        await harness.core.handleAppPause()
        harness.clock.now = harness.clock.now.addingTimeInterval(300)
        await harness.core.handleAppResume()
        XCTAssertEqual(harness.loader.loaded, [])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.nextRelease?.id, v2.release.id)
    }

    func testShouldKeepANextResumeReleaseWaitingAfterAShortBackground() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextResume))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.handleAppResume()
        await harness.core.handleAppPause()
        harness.clock.now = harness.clock.now.addingTimeInterval(299)
        await harness.core.handleAppResume()
        XCTAssertEqual(harness.loader.loaded, [])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.nextRelease, v2.release.release)
    }

    func testShouldSkipOnAMeteredConnectionUnderTheUnmeteredStrategy() async throws {
        let harness = Harness()
        harness.loader.isMetered = true
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual, options: SyncOptions(downloadStrategy: .unmetered))
        XCTAssertEqual(result, .skipped(v2.release.release, reason: .connectionMetered))
    }

    func testShouldResolveAChannelNameThroughTheChannelsIndex() async throws {
        let harness = Harness()
        harness.http.stubJson("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/channels/v1/index.json", ChannelsIndex(channels: [.init(id: Fixture.stagingChannelId, name: "staging")]))
        harness.http.stubJson("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/channels/\(Fixture.stagingChannelId)/ios/v1/index.json", ChannelIndex(sequence: 1, appId: Fixture.appId, channelId: Fixture.stagingChannelId, platform: "ios", releases: []))
        try await harness.core.setChannel(.name("staging"))
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .upToDate(nil))
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: Fixture.stagingChannelId, name: "staging", source: .runtime))
        try await harness.core.setChannel(.name("nowhere"))
        let unknown = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(unknown.reason, FailedReason.channelUnknown.rawValue)
    }

    func testShouldAnswerNoIdForARuntimeNameBeforeASyncResolvedItAndTheIdAfter() async throws {
        let harness = Harness()
        harness.http.stubJson("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/channels/v1/index.json", ChannelsIndex(channels: [.init(id: Fixture.stagingChannelId, name: "staging")]))
        harness.http.stubJson("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/channels/\(Fixture.stagingChannelId)/ios/v1/index.json", ChannelIndex(sequence: 1, appId: Fixture.appId, channelId: Fixture.stagingChannelId, platform: "ios", releases: []))
        try await harness.core.setChannel(.name("staging"))
        let unresolved = await harness.core.channel()
        XCTAssertEqual(unresolved, ChannelResult(id: nil, name: "staging", source: .runtime))
        _ = try await harness.core.sync(trigger: .manual)
        let resolved = await harness.core.channel()
        XCTAssertEqual(resolved, ChannelResult(id: Fixture.stagingChannelId, name: "staging", source: .runtime))
    }

    func testShouldRefuseAChannelIdThatIsNotAUuidAndRequestOnlyTheConfiguredChannel() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1)
        do {
            try await harness.core.setChannel(.id("../../a0000000-0000-4000-8000-0000000000ff/channels/c1/ios/v1/index.json?"))
            XCTFail("expected a plain error")
        } catch is PlainError {}
        let channel = await harness.core.channel()
        XCTAssertEqual(channel, ChannelResult(id: Fixture.channelId, name: nil, source: .config))
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.http.requests.map { $0.url.absoluteString }, [Fixture.indexUrl()])
    }

    func testShouldRefuseEveryStageWithAPlainErrorAndFetchNothingWhenTheConfiguredChannelIdIsNotAUuid() async {
        let harness = Harness(configuration: Fixture.configuration(channelId: "c1/../../other"))
        await assertEveryStageRefusesTheChannelId(harness)
    }

    func testShouldRefuseEveryStageWithAPlainErrorAndFetchNothingWhenAStoredRuntimeChannelIdIsNotAUuid() async {
        let harness = Harness()
        StateStore(store: harness.store).channel = .id("../../a0000000-0000-4000-8000-0000000000ff/channels/c1/ios/v1/index.json?")
        await assertEveryStageRefusesTheChannelId(harness)
    }

    private func assertEveryStageRefusesTheChannelId(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await harness.core.sync(trigger: .manual)
            XCTFail("expected a plain error", file: file, line: line)
        } catch {
            XCTAssertTrue(error is PlainError, file: file, line: line)
        }
        let check: SyncResult? = try? await harness.core.checkForUpdate()
        let download: SyncResult? = try? await harness.core.downloadUpdate()
        XCTAssertNil(check, file: file, line: line)
        XCTAssertNil(download, file: file, line: line)
        XCTAssertTrue(harness.http.requests.isEmpty, file: file, line: line)
    }

    func testShouldFailWithInvalidIndexWhenTheIndexNamesAnotherApp() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        harness.http.stubJson(Fixture.indexUrl(), ChannelIndex(sequence: 1, appId: "a0000000-0000-4000-8000-0000000000ff", channelId: Fixture.channelId, platform: "ios", releases: [v2.release]))
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.reason, FailedReason.indexInvalid.rawValue)
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldFailWithInvalidIndexWhenTheIndexNamesAnotherChannelOrPlatform() async throws {
        let harness = Harness()
        harness.http.stubJson(Fixture.indexUrl(), ChannelIndex(sequence: 1, appId: Fixture.appId, channelId: Fixture.stagingChannelId, platform: "ios", releases: []))
        let otherChannel = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(otherChannel.reason, FailedReason.indexInvalid.rawValue)
        harness.http.stubJson(Fixture.indexUrl(), ChannelIndex(sequence: 1, appId: Fixture.appId, channelId: Fixture.channelId, platform: "android", releases: []))
        let otherPlatform = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(otherPlatform.reason, FailedReason.indexInvalid.rawValue)
    }

    func testShouldFailWithInvalidIndexWhenTheChannelsIndexNamesTheChannelByAnIdThatIsNotAUuid() async throws {
        let harness = Harness()
        harness.http.stubJson("\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/channels/v1/index.json", ChannelsIndex(channels: [.init(id: "../evil", name: "staging")]))
        try await harness.core.setChannel(.name("staging"))
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.reason, FailedReason.indexInvalid.rawValue)
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldMergeAttributesAndRefuseInvalidOnes() async throws {
        let harness = Harness()
        try await harness.core.setAttributes(["plan": "beta", "userId": "42"])
        try await harness.core.setAttributes(["plan": nil])
        let device = await harness.core.deviceResult()
        XCTAssertEqual(device.attributes, ["userId": "42"])
        XCTAssertEqual(device.channel.source, .config)
        XCTAssertEqual(device.fingerprint, "fp1:abc")
        do {
            try await harness.core.setAttributes(["bad key": "x"])
            XCTFail("expected a plain error")
        } catch let error as PlainError {
            XCTAssertTrue(error.message.contains("identifier"))
        }
    }

    func testShouldRefuseAnAttributeValueWithAC1ControlCharacterAndKeepTheStoredOnes() async throws {
        let harness = Harness()
        try await harness.core.setAttributes(["plan": "beta"])
        do {
            try await harness.core.setAttributes(["plan": "beta\u{0085}", "tenant": "acme"])
            XCTFail("expected a plain error")
        } catch is PlainError {}
        let device = await harness.core.deviceResult()
        XCTAssertEqual(device.attributes, ["plan": "beta"])
    }

    func testShouldSendTheEventsWithoutTheReportWhenAStoredAttributeIsOneTheEventsEndpointRefuses() async throws {
        let harness = Harness()
        harness.acknowledgeEvents()
        StateStore(store: harness.store).attributes = ["plan": "beta\u{0085}"]
        harness.publish([Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))], sequence: 1)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let batch = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(harness.http.posts.last).body) as? [String: Any])
        XCTAssertTrue(batch["report"] is NSNull)
        XCTAssertFalse((batch["events"] as? [Any] ?? []).isEmpty)
        let log = await harness.core.debugSnapshot().log
        XCTAssertTrue(log.contains { $0.code == "REPORT_UNREADABLE" })
    }

    func testShouldDownloadOnceWhenTwoDownloadsAndASyncRunAtOnce() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        async let first = harness.core.downloadUpdate()
        async let second = harness.core.downloadUpdate()
        async let synced = harness.core.sync(trigger: .interval)
        let results = try await [first, second, synced]
        XCTAssertEqual(results.map { $0.release?.id }, ["r1", "r1", "r1"])
        XCTAssertFalse(results.contains { $0.status == .failed })
        XCTAssertEqual(harness.http.requests.filter { $0.url.absoluteString == v2.envelope.pack.url }.count, 1)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.filter { $0.type == "downloaded" }.count, 1)
    }

    func testShouldJoinARunningCheckInsteadOfFetchingTheIndexTwice() async throws {
        let harness = Harness()
        harness.publish([], sequence: 1)
        async let first = harness.core.checkForUpdate()
        async let second = harness.core.checkForUpdate()
        let results = try await [first, second]
        XCTAssertEqual(results, [.upToDate(nil), .upToDate(nil)])
        XCTAssertEqual(harness.http.requests.count, 1)
    }

    func testShouldReportChecksOncePerRelease() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), conditions: [.os(range: ">=99")])
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        _ = try await harness.core.sync(trigger: .manual)
        let events = StateStore(store: harness.store).unsentEvents.filter { $0.type == "checked" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].reason, SkippedReason.deviceIncompatible.rawValue)
        XCTAssertEqual(events[0].condition, .os)
    }

    func testShouldSendTheOutboxAndTheReportAfterASyncAndClearThemOnA202() async throws {
        let harness = Harness()
        harness.acknowledgeEvents()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 1)
        XCTAssertEqual(harness.http.posts[0].url.absoluteString, Fixture.eventsUrl())
        XCTAssertEqual(harness.http.posts[0].headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.http.posts[0].body) as? [String: Any])
        let state = StateStore(store: harness.store)
        XCTAssertEqual(body["deviceId"] as? String, state.deviceId)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["sdkVersion"] as? String, "0.0.0")
        XCTAssertEqual((body["events"] as? [[String: Any]])?.map { $0["type"] as? String }, ["checked", "downloaded"])
        let report = try XCTUnwrap(body["report"] as? [String: Any])
        XCTAssertEqual(report["channelId"] as? String, Fixture.channelId)
        XCTAssertEqual(report["channelSource"] as? String, "config")
        XCTAssertEqual(report["binaryVersion"] as? String, "2.4.1")
        XCTAssertEqual(report["fingerprint"] as? String, "fp1:abc")
        XCTAssertEqual(report["embeddedBundleId"] as? String, "embedded")
        XCTAssertTrue(report["releaseId"] is NSNull)
        XCTAssertEqual(state.unsentEvents, [])
        XCTAssertEqual(state.reportedAt, Iso8601.parse("2023-11-14T23:00:00.000Z"))
        XCTAssertEqual(state.acknowledgedReport?.channelId, Fixture.channelId)
        let status = await harness.core.getState()
        XCTAssertEqual(status.lastReportAt, state.reportedAt)
    }

    func testShouldKeepTheOutboxWhenTheEventsEndpointFailsAndRetryAtTheNextSync() async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: 500, body: Data())
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 1)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.count, 2)
        XCTAssertNil(StateStore(store: harness.store).reportedAt)
        harness.acknowledgeEvents()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 2)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [])
    }

    func testShouldDropTheBatchsEventsAndKeepTheReportUnacknowledgedWhenTheEndpointAnswers400() async throws {
        try await assertBatchRefused(status: 400)
    }

    func testShouldDropTheBatchsEventsAndKeepTheReportUnacknowledgedWhenTheEndpointAnswers404() async throws {
        try await assertBatchRefused(status: 404)
    }

    func testShouldDropTheBatchsEventsAndKeepTheReportUnacknowledgedWhenTheEndpointAnswers422() async throws {
        try await assertBatchRefused(status: 422)
    }

    func testShouldKeepTheOutboxWhenTheEndpointAnswers408() async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: 408, body: Data())
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 1)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.count, 2)
        XCTAssertNil(StateStore(store: harness.store).reportedAt)
    }

    func testShouldKeepTheOutboxWhenTheEndpointDoesNotAnswer() async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: 500, body: Data())
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        harness.http.isOffline = true
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 2)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.count, 2)
        let log = await harness.core.debugSnapshot().log
        XCTAssertEqual(log.last?.message, "2 events kept for the next sync: the events endpoint could not be reached")
    }

    func testShouldKeepAnEventEnqueuedWhileARefusedBatchWasInFlight() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        harness.http.stub(Fixture.eventsUrl(), status: 400, body: Data())
        harness.http.whilePosting = { _ = await harness.core.notifyReady() }
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(harness.http.posts.first).body) as? [String: Any])
        XCTAssertEqual((sent["events"] as? [[String: Any]])?.map { $0["type"] as? String }, ["checked", "downloaded", "applied"])
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [.confirmed(releaseId: "r1")])
    }

    func testShouldKeepAnEventEnqueuedWhileAnAcknowledgedBatchWasInFlightWhenTheOutboxWasAtItsCap() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        harness.acknowledgeEvents()
        harness.http.whilePosting = { _ = await harness.core.notifyReady() }
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        StateStore(store: harness.store).unsentEvents = (0..<200).map { DeviceEvent.applied(releaseId: "r-old-\($0)") }
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(harness.http.posts.first).body) as? [String: Any])
        XCTAssertEqual((sent["events"] as? [Any])?.count, 200)
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents, [.confirmed(releaseId: "r1")])
    }

    func testShouldSendTheReportOncePerChangeAndAgainWhenTheMonthBegan() async throws {
        let harness = Harness()
        harness.acknowledgeEvents()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 1)
        try await harness.core.setAttributes(["plan": "beta"])
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 2)
        let changed = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.http.posts[1].body) as? [String: Any])
        XCTAssertEqual((changed["report"] as? [String: Any])?["attributes"] as? [String: String], ["plan": "beta"])
        XCTAssertEqual((changed["events"] as? [Any])?.count, 0)
        harness.clock.now = harness.clock.now.addingTimeInterval(40 * 86_400)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 3)
        let monthly = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.http.posts[2].body) as? [String: Any])
        XCTAssertNotNil(monthly["report"] as? [String: Any])
    }

    func testShouldSendNothingWhenLiveUpdatesAreOffInADebugBuild() async throws {
        let harness = Harness(configuration: Fixture.configuration(enabledInDebugBuilds: false), isDebugBuild: true)
        harness.acknowledgeEvents()
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(result, .skipped(nil, reason: .buildDebug))
        XCTAssertEqual(harness.http.posts.count, 0)
    }

    func testShouldSyncOnStartAndResumeWhenAutoCheckIsOn() async throws {
        let harness = Harness(configuration: Fixture.configuration(autoCheck: true))
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
        harness.clock.now = harness.clock.now.addingTimeInterval(1000)
        harness.restart(configuration: Fixture.configuration(autoCheck: true))
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .resume)
    }

    func testShouldPauseTheReadinessTimerInTheBackgroundAndStartItsFullWindowAgainOnResume() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [10])
        await harness.core.handleAppPause()
        XCTAssertTrue(harness.scheduler.tasks[0].isCancelled)
        await harness.scheduler.fire()
        harness.clock.now = harness.clock.now.addingTimeInterval(60)
        await harness.core.handleAppResume()
        let resumed = await harness.core.getState()
        XCTAssertEqual(resumed.currentRelease?.id, "r1")
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [10])
        await harness.core.handleRendered()
        let confirmed = await harness.core.getState()
        XCTAssertEqual(confirmed.fallbackRelease?.id, "r1")
        XCTAssertTrue(StateStore(store: harness.store).failedBundleIds.isEmpty)
    }

    func testShouldStartTheReadinessTimerAtTheFirstResumeWhenTheAppIsLaunchedIntoTheBackground() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        harness.applicationState.isInBackground = true
        let started = await harness.core.handleAppStart()
        XCTAssertEqual(started, "b2")
        XCTAssertTrue(harness.scheduler.tasks.isEmpty)
        harness.applicationState.isInBackground = false
        await harness.core.handleAppResume()
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [10])
    }

    @MainActor
    func testShouldReadTheApplicationsStateBeforeItBlocksWhenTheHostWaitsOnTheMainThread() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        harness.applicationState.isInBackground = true
        let started = harness.core.handleAppStartBlocking()
        XCTAssertEqual(started, "b2")
        XCTAssertTrue(harness.scheduler.tasks.isEmpty)
    }

    func testShouldArmTheReadinessTimerAtTheResumeWhenAReloadRunsInTheBackground() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.handleAppPause()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertTrue(harness.scheduler.tasks.filter { !$0.isCancelled }.allSatisfy { $0.seconds != 10 })
        await harness.core.handleAppResume()
        XCTAssertEqual(harness.scheduler.tasks.filter { !$0.isCancelled && $0.seconds == 10 }.count, 1)
    }

    func testShouldPauseTheIntervalTimerInTheBackgroundAndReArmItOnResume() async throws {
        let harness = Harness(configuration: Fixture.configuration(autoCheck: true))
        harness.publish([], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [900])
        await harness.core.handleAppPause()
        XCTAssertTrue(harness.scheduler.tasks[0].isCancelled)
        harness.clock.now = harness.clock.now.addingTimeInterval(600)
        await harness.core.handleAppResume()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
        XCTAssertEqual(harness.scheduler.tasks.map { $0.seconds }, [900, 300])
    }

    func testShouldDeleteTheServedTreesAndFilesOfBundlesNoKeptReleaseLists() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        let v4 = Fixture.release(number: 3, bundleId: "b4", content: Data("<html>v4</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        harness.publish([v2, v3, v4], sequence: 3, etag: "\"e3\"")
        _ = try await harness.core.sync(trigger: .manual, options: SyncOptions(installStrategy: .nextStart))
        for bundleId in ["b2", "b3", "b4"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.loader.projectionDirectory(bundleId: bundleId).appendingPathComponent("index.html").path), bundleId)
        }
        harness.loader.served = "b4"
        harness.restart(configuration: Fixture.configuration(installStrategy: .immediate))
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        let status = await harness.core.getState()
        XCTAssertEqual(status.currentRelease?.bundleId, "b4")
        XCTAssertEqual(status.fallbackRelease?.bundleId, "b3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.loader.projectionDirectory(bundleId: "b2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.loader.projectionDirectory(bundleId: "b3").appendingPathComponent("index.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.loader.projectionDirectory(bundleId: "b4").appendingPathComponent("index.html").path))
        XCTAssertEqual(harness.files.bundleIds(), ["b3", "b4"])
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex("js-b2")))
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v3</html>")))
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v4</html>")))
    }

    func testShouldClearUpdatesToTheEmbeddedBundleAndKeepTheIdentity() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        try await harness.core.setAttributes(["plan": "beta"])
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.handleRendered()
        await harness.core.clearUpdates()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, [])
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertEqual(harness.loader.loaded.last, .some(nil))
        let device = await harness.core.deviceResult()
        XCTAssertEqual(device.attributes, ["plan": "beta"])
    }

    func testShouldStopAfterTheCheckUnderTheManualDownloadStrategyAndDownloadOnCall() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .manual, downloadStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        let synced = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(synced, .available(v2.release.release, notes: "notes 1", downloadBytes: 15))
        XCTAssertFalse(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertEqual(harness.listener.available.count, 1)
        let downloaded = try await harness.core.downloadUpdate()
        XCTAssertEqual(downloaded, .downloaded(v2.release.release, notes: "notes 1"))
        XCTAssertTrue(harness.files.hasFile(sha256: Hashing.sha256Hex("<html>v2</html>")))
        XCTAssertEqual(harness.listener.downloaded.map { $0.installAt }, [.manual])
        XCTAssertEqual(harness.loader.loaded, [])
        let state = await harness.core.getState()
        XCTAssertEqual(state.nextRelease, v2.release.release)
        XCTAssertEqual(state.lastCheck?.result.status, .available)
        let applied = await harness.core.applyUpdate()
        XCTAssertEqual(applied, ApplyResult(status: .applied, release: v2.release.release))
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let nothing = await harness.core.applyUpdate()
        XCTAssertEqual(nothing, ApplyResult(status: .nothingToApply, release: v2.release.release))
    }

    func testShouldDownloadOnCallWhateverTheConnectionUnderTheUnmeteredStrategy() async throws {
        let harness = Harness(configuration: Fixture.configuration(downloadStrategy: .unmetered))
        harness.loader.isMetered = true
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let skipped = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(skipped, .skipped(v2.release.release, reason: .connectionMetered))
        let downloaded = try await harness.core.downloadUpdate()
        XCTAssertEqual(downloaded, .downloaded(v2.release.release, notes: "notes 1"))
        XCTAssertEqual(harness.listener.downloaded.map { $0.installAt }, [.nextStart])
    }

    func testShouldInstallAMandatoryReleaseAtOnceWhateverTheInstallStrategy() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .immediate)
        XCTAssertEqual(result.release?.isMandatory, true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertTrue(harness.listener.downloaded.isEmpty)
    }

    func testShouldHandAMandatoryReleaseToTheAppUnderTheManualMandatoryStrategy() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart, mandatoryInstallStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .updated(v2.release.release, notes: "notes 1", installAt: .manual))
        XCTAssertEqual(harness.listener.downloaded.map { $0.release.isMandatory }, [true])
        XCTAssertEqual(harness.loader.loaded, [])
        harness.loader.served = nil
        harness.restart(configuration: Fixture.configuration(installStrategy: .nextStart, mandatoryInstallStrategy: .manual))
        await harness.core.handleAppStart()
        let state = await harness.core.getState()
        XCTAssertNil(state.currentRelease)
        XCTAssertEqual(state.nextRelease, v2.release.release)
    }

    func testShouldTreatTheNewestReleaseAsMandatoryWhenAMandatoryOneWasMissed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart, mandatoryInstallStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.release?.id, "r2")
        XCTAssertEqual(result.release?.isMandatory, true)
        XCTAssertEqual(result.installAt, .manual)
    }

    func testShouldCarryTheAppsRollbackReasonOnTheFailureEvent() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        try await harness.core.rollbackUpdate(detail: "checkout crashed")
        let failed = StateStore(store: harness.store).unsentEvents.last { $0.type == "failed" }
        XCTAssertEqual(failed?.reason, RollbackReason.appRequested.rawValue)
        XCTAssertEqual(failed?.detail, "checkout crashed")
        do {
            try await harness.core.rollbackUpdate(detail: "a\nb")
            XCTFail("expected a plain error")
        } catch is PlainError {}
    }

    func testShouldLetTheStartsSyncDownloadOnlyAfterTheCleanupSoNoFileItWritesIsDeleted() async throws {
        let harness = Harness(configuration: Fixture.configuration(autoCheck: true))
        let content = Data("<html>shared</html>".utf8)
        try harness.files.writeFile(content, sha256: Hashing.sha256Hex(content))
        try harness.files.writeManifest(BundleManifest(appId: Fixture.appId, bundleVersion: "0.9.0", files: [.init(path: "index.html", sha256: Hashing.sha256Hex(content), sizeBytes: content.count)], platforms: ["ios"]), bundleId: "b-unused")
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: content)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.files.bundleIds(), ["b2"])
        XCTAssertTrue(harness.files.isComplete(v2.manifest, embedded: harness.embedded))
    }

    func testShouldSyncAndCleanUpAtAStartThatRollsBackACrash() async throws {
        let harness = Harness(configuration: Fixture.configuration(autoCheck: true))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        harness.loader.served = "b2"
        harness.restart(configuration: Fixture.configuration(autoCheck: true))
        await harness.core.handleAppStart()
        harness.restart(configuration: Fixture.configuration(autoCheck: true))
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.listener.rolledBack.last?.reason, .appCrashed)
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
        XCTAssertEqual(harness.files.bundleIds(), [])
    }

    func testShouldAnnounceTheRollbackWhenTheReloadRunsAndNotBefore() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.setRestartAllowed(false)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut])
    }

    func testShouldAnnounceARollbackAtTheNextStartWhenTheProcessEndedWhileItsReloadWasHeld() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        await harness.core.setRestartAllowed(false)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
        await restartOnTheServedBundle(harness)
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut])
        let ready = await harness.core.notifyReady()
        XCTAssertTrue(ready.isRolledBack)
        XCTAssertEqual(ready.rollbackReason, .readinessTimedOut)
        XCTAssertEqual(ready.previousRelease?.id, "r1")
    }

    func testShouldAnnounceARollbackAgainAtTheNextStartWhenTheAppNeverCameUpAfterTheReload() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        try await harness.core.rollbackUpdate(detail: nil)
        XCTAssertEqual(harness.listener.rolledBack.count, 1)
        await restartOnTheServedBundle(harness)
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.appRequested, .appRequested])
    }

    func testShouldNotAnnounceARollbackAgainAtTheNextStartWhenTheAppRenderedAfterTheReload() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        try await harness.core.rollbackUpdate(detail: nil)
        await harness.core.handleRendered()
        await restartOnTheServedBundle(harness)
        XCTAssertEqual(harness.listener.rolledBack.count, 1)
        XCTAssertNil(StateStore(store: harness.store).pendingRollbackEvent)
    }

    func testShouldNotAnnounceARollbackAgainAtTheNextStartWhenTheAppNotifiedReadyAfterTheReload() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        try await harness.core.rollbackUpdate(detail: nil)
        _ = await harness.core.notifyReady()
        await restartOnTheServedBundle(harness)
        XCTAssertEqual(harness.listener.rolledBack.count, 1)
        XCTAssertNil(StateStore(store: harness.store).pendingRollbackEvent)
    }

    func testShouldAnnounceOnceAtAStartThatRollsBackACrashItself() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        harness.restart()
        await harness.core.handleAppStart()
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.appCrashed])
    }

    func testShouldKeepTheNoticeWhenTheReadinessTimerRanOutAndNothingRendered() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut])
        XCTAssertEqual(StateStore(store: harness.store).pendingRollbackEvent?.reason, .readinessTimedOut)
        await restartOnTheServedBundle(harness)
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut, .readinessTimedOut])
    }

    func testShouldKeepTheNoticeWhenTheAppRendersWhileTheRollbacksReloadIsHeld() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        await harness.core.setRestartAllowed(false)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        await harness.core.handleRendered()
        XCTAssertEqual(StateStore(store: harness.store).pendingRollbackEvent?.reason, .readinessTimedOut)
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut])
        XCTAssertEqual(StateStore(store: harness.store).pendingRollbackEvent?.reason, .readinessTimedOut)
    }

    func testShouldRemoveTheNoticeAtTheStartOfANewBinary() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        try await harness.core.rollbackUpdate(detail: nil)
        harness.loader.served = nil
        harness.restart(configuration: Fixture.configuration(builtAt: Fixture.builtAt.addingTimeInterval(86_400)))
        await harness.core.handleAppStart()
        XCTAssertEqual(harness.listener.rolledBack.count, 1)
        XCTAssertNil(StateStore(store: harness.store).pendingRollbackEvent)
        let ready = await harness.core.notifyReady()
        XCTAssertFalse(ready.isRolledBack)
    }

    func testShouldRemoveTheNoticeWhenTheAppClearsUpdates() async throws {
        let harness = try await harnessOnAnUnconfirmedRelease()
        await harness.core.setRestartAllowed(false)
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        await harness.core.clearUpdates()
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        XCTAssertNil(StateStore(store: harness.store).pendingRollbackEvent)
        XCTAssertNil(StateStore(store: harness.store).lastRollback)
        await restartOnTheServedBundle(harness)
        XCTAssertTrue(harness.listener.rolledBack.isEmpty)
    }

    func testShouldFailOfflineNotUnknownWhenAChannelNameCannotBeResolved() async throws {
        let harness = Harness()
        try await harness.core.setChannel(.name("staging"))
        harness.http.isOffline = true
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.reason, FailedReason.deviceOffline.rawValue)
        XCTAssertEqual(harness.listener.failed.map { $0.reason }, [.deviceOffline])
    }

    func testShouldTakeTheStreamedDeltaWhenTheDeviceIsTwoReleasesBehind() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        _ = await harness.core.notifyReady()
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        let v4 = Fixture.release(number: 3, bundleId: "b4", content: Data("<html>v4</html>".utf8))
        harness.publish([v3, v4], sequence: 2, etag: "\"e2\"")
        let precomputedDeltaUrl = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/b4/deltas/b3"
        harness.http.stubJson(v4.release.manifestUrl, ManifestEnvelope(bundleId: "b4", createdAt: v4.envelope.createdAt, manifest: v4.envelope.manifest, pack: v4.envelope.pack, deltas: [.init(baseBundleId: "b3", url: precomputedDeltaUrl, sizeBytes: v4.pack.count)]))
        let streamedDeltaUrl = "\(Fixture.updatesBaseUrl)/v1/apps/\(Fixture.appId)/bundles/b4/deltas/b2"
        harness.http.stub(streamedDeltaUrl, body: v4.pack)
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .updated)
        XCTAssertEqual(result.release?.bundleId, "b4")
        XCTAssertTrue(harness.http.requests.contains { $0.url.absoluteString == streamedDeltaUrl })
        XCTAssertFalse(harness.http.requests.contains { $0.url.absoluteString == precomputedDeltaUrl || $0.url.absoluteString == v4.envelope.pack.url })
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.last { $0.type == "downloaded" }?.packKind, PackKind.streamed.rawValue)
    }

    func testShouldFetchTheDeltaAgainstTheEmbeddedBundleOnTheFirstUpdate() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        let deltaUrl = "\(Fixture.filesBaseUrl)/apps/\(Fixture.appId)/bundles/b2/deltas/embedded"
        harness.publish([v2], sequence: 1)
        harness.http.stubJson(v2.release.manifestUrl, ManifestEnvelope(bundleId: "b2", createdAt: v2.envelope.createdAt, manifest: v2.envelope.manifest, pack: v2.envelope.pack, deltas: [.init(baseBundleId: "embedded", url: deltaUrl, sizeBytes: v2.pack.count)]))
        harness.http.stub(deltaUrl, body: v2.pack)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.status, .updated)
        XCTAssertTrue(harness.http.requests.contains { $0.url.absoluteString == deltaUrl })
        XCTAssertEqual(StateStore(store: harness.store).unsentEvents.first { $0.type == "downloaded" }?.packKind, PackKind.delta.rawValue)
    }

    func testShouldDiscardADownloadedReleaseRevokedBeforeTheStartThatWouldInstallIt() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.publish([v2], sequence: 2, revoked: ["r1"], etag: "\"e2\"")
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .upToDate(nil))
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertNil(status.nextRelease)
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        XCTAssertEqual(harness.loader.loaded, [nil])
    }

    func testShouldDiscardADownloadedReleaseThatLeftTheIndexInsteadOfApplyingIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let downloaded = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(downloaded, .updated(v2.release.release, notes: "notes 1", installAt: .manual))
        harness.publish([], sequence: 2, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        let result = await harness.core.applyUpdate()
        XCTAssertEqual(result, ApplyResult(status: .nothingToApply, release: nil))
        XCTAssertEqual(harness.loader.loaded, [])
        let status = await harness.core.getState()
        XCTAssertNil(status.nextRelease)
    }

    func testShouldBeginTheStartSyncAtOnceWhenTheRunningReleaseIsConfirmed() async throws {
        let harness = Harness()
        try await restartOnAConfirmedRelease(harness, configuration: Fixture.configuration(autoCheck: true))
        await harness.core.handleAppStart()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
    }

    func testShouldBeginTheStartSyncAtTheConfirmationNotTheFirstRenderWhenTheRunningReleaseIsNew() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart(configuration: Fixture.configuration(autoCheck: true, readySignal: .manual))
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .manual)
        _ = await harness.core.notifyReady()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .start)
    }

    func testShouldBeginNoStartSyncWhenAutoCheckIsOff() async throws {
        let harness = Harness()
        try await restartOnAConfirmedRelease(harness, configuration: Fixture.configuration(autoCheck: false))
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = await harness.core.notifyReady()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(StateStore(store: harness.store).lastCheck?.trigger, .manual)
    }

    func testShouldReloadAnImmediateInstallAtTheFirstRenderAndNotBeforeWhenItIsReadyBeforeIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .immediate)
        XCTAssertEqual(harness.loader.loaded, [])
        let held = await harness.core.getState()
        XCTAssertNil(held.currentRelease)
        XCTAssertEqual(held.nextRelease, v2.release.release)
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
    }

    func testShouldReloadAnImmediateInstallAtNotifyReadyAndNotBeforeWhenItIsReadyBeforeIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        _ = await harness.core.notifyReady()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
    }

    func testShouldReloadAMandatoryReleaseAtTheFirstRenderAndNotBeforeWhenItIsReadyBeforeIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result.installAt, .immediate)
        XCTAssertEqual(harness.loader.loaded, [])
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
    }

    func testShouldReloadAMandatoryReleaseAtNotifyReadyAndNotBeforeWhenItIsReadyBeforeIt() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        _ = await harness.core.notifyReady()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
    }

    func testShouldApplyAnUpdateAtTheFirstRenderAndNotBeforeWhileRestartsAreNotAllowed() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .manual))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        let applied = await harness.core.applyUpdate()
        XCTAssertEqual(applied, ApplyResult(status: .applied, release: v2.release.release))
        XCTAssertEqual(harness.loader.loaded, [])
        let held = await harness.core.getState()
        XCTAssertNil(held.currentRelease)
        XCTAssertEqual(held.nextRelease, v2.release.release)
        await harness.core.setRestartAllowed(false)
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let installed = await harness.core.getState()
        XCTAssertEqual(installed.currentRelease, v2.release.release)
    }

    func testShouldClearUpdatesAtTheFirstRenderAndNotBeforeWhileRestartsAreNotAllowed() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.clearUpdates()
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertEqual(harness.files.bundleIds(), ["b2"])
        await harness.core.setRestartAllowed(false)
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, [nil])
        XCTAssertEqual(harness.files.bundleIds(), [])
        let cleared = await harness.core.getState()
        XCTAssertNil(cleared.nextRelease)
    }

    func testShouldRollBackAtOnceWhenNothingRendered() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        try await harness.core.rollbackUpdate(detail: nil)
        XCTAssertEqual(harness.loader.loaded, [nil])
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.appRequested])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, ["b2"])
    }

    func testShouldRunARestartHeldByTheAppAndTheStartOnceWhenTheAppAllowsRestartsAfterTheFirstRender() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, [])
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
    }

    func testShouldRunARestartHeldByTheAppAndTheStartOnceWhenTheFirstRenderComesAfterTheAppAllowsRestarts() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, [])
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
    }

    func testShouldRollBackAndReloadAtTheReadyTimeoutWhenNothingRendered() async throws {
        let harness = Harness()
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        harness.loader.served = "b2"
        harness.restart()
        await harness.core.handleAppStart()
        await harness.scheduler.fire()
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.loader.loaded, [nil])
        XCTAssertEqual(harness.listener.rolledBack.map { $0.reason }, [.readinessTimedOut])
        let status = await harness.core.getState()
        XCTAssertNil(status.currentRelease)
        XCTAssertEqual(status.failedBundleIds, ["b2"])
    }

    func testShouldHoldTheNextRestartUntilTheReloadedAppRendersWhenTheCoreReloaded() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        let held = await harness.core.getState()
        XCTAssertEqual(held.currentRelease, v2.release.release)
        XCTAssertEqual(held.nextRelease, v3.release.release)
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2", "b3"])
    }

    func testShouldReloadOnceWhenTheAppAppliesAnUpdateWhileTheAppHoldsARestart() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(false)
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        _ = await harness.core.applyUpdate()
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        await harness.core.handleRendered()
        await harness.core.setRestartAllowed(true)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
    }

    func testShouldReloadOnceWhenTheAppRollsBackWhileTheStartHoldsARestart() async throws {
        let harness = Harness()
        try await restartOnAConfirmedRelease(harness, configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 2, etag: "\"e2\"")
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        try await harness.core.rollbackUpdate(detail: nil)
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
        await harness.core.handleRendered()
        XCTAssertEqual(harness.loader.loaded, ["b2", nil])
    }

    func testShouldSwitchToAHeldImmediateInstallAtTheNextStartWhenItNeverRan() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        harness.loader.served = "b2"
        harness.restart(configuration: Fixture.configuration(installStrategy: .immediate))
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertEqual(started.currentRelease, v2.release.release)
        XCTAssertNil(started.nextRelease)
    }

    func testShouldSwitchToAHeldMandatoryReleaseAtTheNextStartWhenItNeverRan() async throws {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .nextStart))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8), isMandatory: true)
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, [])
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        harness.loader.served = "b2"
        harness.restart(configuration: Fixture.configuration(installStrategy: .nextStart))
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertEqual(started.currentRelease, v2.release.release)
        XCTAssertNil(started.nextRelease)
    }

    func testShouldRunTheEmbeddedBundleAtTheNextStartWhenAHeldMoveFromARevokedReleaseNeverRan() async throws {
        let harness = Harness()
        try await restartOnAConfirmedRelease(harness, configuration: Fixture.configuration())
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 2, revoked: ["r1"], etag: "\"e2\"")
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .skipped(nil, reason: .releaseRevoked))
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertEqual(harness.loader.persisted, .some(nil))
        harness.loader.served = nil
        harness.restart()
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertNil(started.currentRelease)
        XCTAssertNil(started.nextRelease)
    }

    func testShouldRunTheOlderReleaseAtTheNextStartWhenAHeldMoveFromARevokedReleaseNeverRan() async throws {
        let configuration = Fixture.configuration(mandatoryInstallStrategy: .manual)
        let harness = Harness(configuration: configuration)
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        let v3 = Fixture.release(number: 2, bundleId: "b3", content: Data("<html>v3</html>".utf8))
        harness.publish([v2, v3], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual, options: SyncOptions(installStrategy: .immediate))
        await harness.core.handleRendered()
        harness.restart(configuration: configuration)
        harness.publish([v2, v3], sequence: 2, revoked: ["r2"], etag: "\"e2\"")
        await harness.core.handleAppStart()
        let result = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(result, .skipped(v2.release.release, reason: .releaseRevoked))
        XCTAssertEqual(harness.loader.loaded, ["b3"])
        XCTAssertEqual(harness.loader.persisted, .some("b2"))
        harness.loader.served = "b2"
        harness.restart(configuration: configuration)
        await harness.core.handleAppStart()
        let started = await harness.core.getState()
        XCTAssertEqual(started.currentRelease?.id, "r1")
        XCTAssertNil(started.nextRelease)
    }

    /// A batch the endpoint refuses loses its events and leaves the report unacknowledged, so the next sync sends the report alone.
    private func assertBatchRefused(status: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let harness = Harness()
        harness.http.stub(Fixture.eventsUrl(), status: status, body: Data())
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        let state = StateStore(store: harness.store)
        XCTAssertEqual(state.unsentEvents, [], file: file, line: line)
        XCTAssertNil(state.reportedAt, file: file, line: line)
        XCTAssertNil(state.acknowledgedReport, file: file, line: line)
        _ = try await harness.core.sync(trigger: .manual)
        await harness.core.waitForBackgroundWork()
        XCTAssertEqual(harness.http.posts.count, 2, file: file, line: line)
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: harness.http.posts[1].body) as? [String: Any], file: file, line: line)
        XCTAssertEqual((next["events"] as? [Any])?.count, 0, file: file, line: line)
        XCTAssertNotNil(next["report"] as? [String: Any], file: file, line: line)
    }

    /// A run that installs v2 at once after the first render and has not confirmed it: its readiness timer is the one scheduled.
    private func harnessOnAnUnconfirmedRelease() async throws -> Harness {
        let harness = Harness(configuration: Fixture.configuration(installStrategy: .immediate))
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual)
        XCTAssertEqual(harness.loader.loaded, ["b2"])
        XCTAssertEqual(harness.scheduler.tasks.count, 1)
        return harness
    }

    /// The process ends, and the next one starts on the bundle the core persisted.
    private func restartOnTheServedBundle(_ harness: Harness) async {
        harness.loader.served = harness.loader.persisted ?? nil
        harness.restart(configuration: Fixture.configuration(installStrategy: .immediate))
        await harness.core.handleAppStart()
    }

    /// A first run that installs v2 and confirms it, then the next start's core over the same store and files.
    private func restartOnAConfirmedRelease(_ harness: Harness, configuration: Configuration) async throws {
        let v2 = Fixture.release(number: 1, bundleId: "b2", content: Data("<html>v2</html>".utf8))
        harness.publish([v2], sequence: 1)
        await harness.core.handleAppStart()
        await harness.core.handleRendered()
        _ = try await harness.core.sync(trigger: .manual, options: SyncOptions(installStrategy: .immediate))
        await harness.core.handleRendered()
        harness.restart(configuration: configuration)
    }
}
