import Foundation

/// The state machine every framework shares: three named releases, a readiness gate and one cycle of three stages.
public actor Core {
    /// How far a cycle goes: the check alone, the download whatever the strategy says, or the whole sync.
    enum Stage {
        case check, download, sync
    }

    /// A restart held at the gate and who asked for it: the app's own is never held by `setRestartAllowed(false)`.
    private struct QueuedRestart {
        let isAskedByApp: Bool
        let restart: () -> Void
    }

    /// How the channel in effect resolved: the runtime choice, a name through the channels index, else the build's own.
    enum ChannelResolution {
        case id(String)
        case offline
        case unknown
        case invalid(String)
        /// The build carries no channel and the app set none at runtime.
        case missing
    }

    /// What a build without a channel answers, without a request: it can never update until the app sets a channel at runtime.
    static let missingChannelMessage = "The build carries no channel: it was built without a token or offline, so the channel's name was never resolved. Build it with a token to receive updates."

    public let configuration: Configuration
    private let device: DeviceFacts
    private let state: StateStore
    private let files: FileStore
    private let embedded: EmbeddedBundle
    private let downloader: Downloader
    private let http: HttpClient
    private let loader: BundleLoader
    private let listener: CoreListener
    private let scheduler: Scheduler
    private let clock: Clock

    private var readyTimer: ScheduledTask?
    /// The background stopped the readiness timer, and the resume starts its full window again.
    private var isReadyTimerPaused = false
    private var intervalTimer: ScheduledTask?
    /// The one cycle that runs, and its stage: no two stages ever download beside each other.
    private var runningCycle: (stage: Stage, task: Task<SyncResult, Never>)?
    private var isRestartAllowed = true
    private var queuedRestart: QueuedRestart?
    /// The app is up in this run: its first render, `notifyReady()` or the readiness timeout settles the start, and every reload the core performs unsettles it.
    private var hasStartSettled = false
    private var isStartSyncPending = false
    private var isSendingDeviceEvents = false
    /// The events enqueued while a batch is on its way: never part of it, so they stay in the outbox whatever the answer.
    private var eventCountEnqueuedInFlight = 0
    private var backgroundedAt: Date?
    private var resolvedChannelName: (name: String, id: String)?
    /// The stored rollback notice was announced in this process, so the app coming up next has received it.
    private var hasAnnouncedRollback = false
    /// The release a switch replaced in this run, `notifyReady()`'s `previousRelease` until it is read.
    private var releaseBeforeSwitch: Release?
    /// This session's log, the newest last, behind the debug screen.
    private var logEntries: [LogEntry] = []
    /// The work a call starts beside its answer — the automatic cycles, the batches and the cleanup — until it ends.
    private var backgroundWork: [UUID: Task<Void, Never>] = [:]
    /// The cleanup the start leaves behind it, which every cycle waits for, since a download writes files no kept release lists yet.
    private var unusedFilesDeletion: Task<Void, Never>?

    public init(configuration: Configuration, device: DeviceFacts, store: KeyValueStore, files: FileStore, embedded: EmbeddedBundle, http: HttpClient, loader: BundleLoader, listener: CoreListener, scheduler: Scheduler = DispatchScheduler(), clock: Clock = SystemClock(), temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.configuration = configuration
        self.device = device
        self.state = StateStore(store: store)
        self.files = files
        self.embedded = embedded
        self.downloader = Downloader(configuration: configuration, platform: device.platform, files: files, embedded: embedded, http: http, temporaryDirectory: temporaryDirectory)
        self.http = http
        self.loader = loader
        self.listener = listener
        self.scheduler = scheduler
        self.clock = clock
    }

    // MARK: Lifecycle

    /// The longest a host's synchronous start waits for the start's answer before it serves the embedded bundle.
    public static let startTimeout: TimeInterval = 2

    /// The start of a run: the binary's floor, the files on disk, the previous run's verdict, the pending switch, a rollback the app
    /// has not come up after and the gate. Answers the bundle the host serves, `nil` for the embedded one, without awaiting the
    /// network: the start's check and the cleanup run after it returns, so a host waiting on the start never waits on them.
    @discardableResult
    public func handleAppStart() -> String? {
        if state.pendingRollbackEvent == nil {
            state.lastRollback = nil
        }
        if state.lastBuiltAt != configuration.builtAt || hasReleaseWithoutManifest() {
            dropStoredReleases()
        }
        if isCurrentReleaseUnconfirmed() {
            rollbackCurrentRelease(reason: .appCrashed, detail: nil)
        }
        discardNextReleaseThatLeftTheIndex()
        if let next = state.nextRelease, shouldSwitchAtStart(to: next) {
            switchToNextRelease()
        }
        loadBundle()
        if !hasAnnouncedRollback {
            announceRollback()
        }
        if isCurrentReleaseUnconfirmed() {
            startReadyTimer()
            isStartSyncPending = true
        } else if configuration.autoCheck {
            startAutomaticCycle(trigger: .start)
        }
        unusedFilesDeletion = startBackgroundWork { self.deleteUnusedFiles() }
        return state.currentRelease?.bundleId
    }

    /// The start for a host that resolves its bundle in synchronous code before its WebView or JavaScript loads: `handleAppStart()`'s
    /// answer, waited for at most `startTimeout`. Without an answer in time it answers the embedded bundle, and the start, once it
    /// runs, reloads the host into the bundle it resolved, as it does whenever the host serves another one.
    public nonisolated func handleAppStartBlocking() -> String? {
        return handleAppStartBlocking(timeout: Core.startTimeout)
    }

    nonisolated func handleAppStartBlocking(timeout: TimeInterval) -> String? {
        let answer = StartAnswer()
        Task.detached(priority: .userInitiated) {
            answer.resolve(await self.handleAppStart())
        }
        return answer.wait(timeout: timeout) ?? nil
    }

    /// A mandatory release follows its own strategy, so one the app took over waits across starts; any other switches under `next-start`; a bundle the WebView already serves is adopted.
    private func shouldSwitchAtStart(to next: Release) -> Bool {
        if loader.servedBundleId() == next.bundleId { return true }
        if next.isMandatory { return configuration.mandatoryInstallStrategy == .immediate }
        return configuration.installStrategy == .nextStart
    }

    /// A release installs on resume when its strategy is `next-resume`: a mandatory one follows `mandatoryInstallStrategy`, which has
    /// no `next-resume`, so one the app took over is never installed behind its back.
    private func shouldInstallOnResume(_ next: Release) -> Bool {
        return resolveInstallStrategy(isMandatory: next.isMandatory, options: SyncOptions()) == .nextResume
    }

    /// The first render of the run, the readiness signal when `readySignal` is `render`, settles the start whatever it is.
    public func handleRendered() {
        if configuration.readySignal == .render {
            confirmCurrentRelease()
        }
        settleStart()
    }

    /// Ends the gate when `readySignal` is `manual`, settles the start, and tells the app whether this start follows a rollback or a
    /// switch, `previousRelease` the release that ran before it; each is told once.
    public func notifyReady() -> NotifyReadyResult {
        confirmCurrentRelease()
        let rollback = state.lastRollback
        state.lastRollback = nil
        let previousRelease = rollback?.from ?? releaseBeforeSwitch
        releaseBeforeSwitch = nil
        let result = NotifyReadyResult(currentRelease: state.currentRelease, previousRelease: previousRelease, isRolledBack: rollback != nil, rollbackReason: rollback?.reason)
        settleStart()
        return result
    }

    /// The background: the interval timer stops, since interval checks belong to the foreground, the readiness timer stops, since an
    /// app that cannot render there proves nothing, and the moment is kept for `next-resume`.
    public func handleAppPause() {
        backgroundedAt = clock.now
        intervalTimer?.cancel()
        intervalTimer = nil
        pauseReadyTimer()
    }

    /// A resume starts a paused readiness window again, installs a `next-resume` release after enough time in the background, else
    /// checks when the interval has passed.
    public func handleAppResume() {
        let backgroundDuration = backgroundedAt.map { clock.now.timeIntervalSince($0) }
        backgroundedAt = nil
        resumeReadyTimer()
        discardNextReleaseThatLeftTheIndex()
        if let duration = backgroundDuration, let next = state.nextRelease, shouldInstallOnResume(next), duration >= configuration.installOnResumeAfter {
            installNextRelease()
            return
        }
        guard configuration.autoCheck else { return }
        if let elapsed = state.lastSyncAt.map({ clock.now.timeIntervalSince($0) }), elapsed < configuration.checkInterval {
            scheduleIntervalSync(after: configuration.checkInterval - elapsed)
        } else {
            startAutomaticCycle(trigger: .resume)
        }
    }

    /// The start's, the resume's and the interval's cycle; a device without a channel starts none, since it could only fail.
    private func startAutomaticCycle(trigger: SyncTrigger) {
        guard hasChannel else { return }
        startBackgroundWork { _ = try? await self.sync(trigger: trigger) }
    }

    @discardableResult
    private func startBackgroundWork(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            await work()
            backgroundWork[id] = nil
        }
        backgroundWork[id] = task
        return task
    }

    /// Returns once no background work runs, the work it started meanwhile included: what a test waits on instead of a sleep.
    func waitForBackgroundWork() async {
        while let work = backgroundWork.values.first {
            await work.value
        }
    }

    // MARK: The three stages

    /// One full cycle; a second call while one runs joins the running one. Each stage throws the plain error, fetching nothing, for a
    /// channel id in effect that is not a UUID.
    public func sync(trigger: SyncTrigger, options: SyncOptions = SyncOptions()) async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: trigger, stage: .sync, options: options)
    }

    /// The first stage: fetch and evaluate, download nothing.
    public func checkForUpdate() async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: .manual, stage: .check, options: SyncOptions())
    }

    /// The second stage: download and verify the update the check finds, whatever `downloadStrategy` says, then install per the strategies.
    public func downloadUpdate() async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: .manual, stage: .download, options: SyncOptions())
    }

    /// One cycle at a time: a call joins the running cycle of its own stage, and waits for one of another stage before it starts its own.
    private func runCycle(trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        await unusedFilesDeletion?.value
        while let running = runningCycle {
            if running.stage == stage {
                return await running.task.value
            }
            _ = await running.task.value
        }
        let task = Task { () -> SyncResult in
            let result = await performCycle(trigger: trigger, stage: stage, options: options)
            runningCycle = nil
            return result
        }
        runningCycle = (stage, task)
        return await task.value
    }

    /// The third stage: apply the downloaded update and reload the app, now or, before the app is up in this run, once it is.
    public func applyUpdate() -> ApplyResult {
        discardNextReleaseThatLeftTheIndex()
        guard let next = state.nextRelease else {
            return ApplyResult(status: .nothingToApply, release: state.currentRelease)
        }
        restartThroughGate(isAskedByApp: true) { [self] in
            switchToNextRelease()
            reloadApp()
        }
        return ApplyResult(status: .applied, release: next)
    }

    private func performCycle(trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        let result = await resolveCycle(trigger: trigger, stage: stage, options: options)
        if stage != .download {
            state.lastCheck = LastCheck(at: clock.now, trigger: trigger, result: result)
        }
        if stage == .sync {
            state.lastSyncAt = clock.now
            scheduleIntervalSync(after: configuration.checkInterval)
        }
        record(LogEntry.ofCycle(result, trigger: trigger, at: clock.now))
        if result.status == .failed, let reason = result.reason.flatMap(FailedReason.init(rawValue:)) {
            listener.updateFailed(UpdateFailedEvent(release: result.release, reason: reason, message: result.message ?? "", trigger: trigger))
        }
        startBackgroundWork { await self.sendDeviceEvents() }
        return result
    }

    private func resolveCycle(trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        let current = state.currentRelease
        if isDisabledInThisBuild {
            return .skipped(current, reason: .buildDebug)
        }
        let channelId: String
        switch await resolveChannelId() {
        case .id(let id): channelId = id
        case .offline: return .failed(current, reason: .deviceOffline, message: "The channels index could not be fetched to resolve the channel name")
        case .unknown: return .failed(current, reason: .channelUnknown, message: "The channel set at runtime is not in the app's channels index")
        case .invalid(let message): return .failed(current, reason: .indexInvalid, message: message)
        case .missing: return .failed(current, reason: .channelUnknown, message: Core.missingChannelMessage)
        }
        let index: ChannelIndex
        switch await fetchChannelIndex(channelId: channelId) {
        case .index(let fetched): index = fetched
        case .offline: return .failed(current, reason: .deviceOffline, message: "The channel index could not be fetched and no cached copy exists")
        case .invalid(let message): return .failed(current, reason: .indexInvalid, message: message)
        case .absent: return .upToDate(current)
        case .gone:
            state.channel = nil
            return await resolveCycle(trigger: trigger, stage: stage, options: options)
        }
        switch Evaluator.evaluate(index, device: deviceInfo()) {
        case .upToDate:
            return .upToDate(current)
        case .available(let target, let isMandatory):
            recordChecked(target, in: index, status: .available, skip: nil)
            return await update(to: target, isMandatory: isMandatory, trigger: trigger, stage: stage, options: options)
        case .skipped(let release, .releaseRevoked, _):
            if stage == .check {
                return .skipped(release?.release, reason: .releaseRevoked)
            }
            guard let target = release else {
                revertToEmbedded()
                return .skipped(nil, reason: .releaseRevoked)
            }
            let outcome = await install(target, isMandatory: true, strategy: .immediate, trigger: trigger, stage: .sync, isDownloadForced: true)
            return outcome.status == .failed ? outcome : .skipped(target.release, reason: .releaseRevoked)
        case .skipped(let release, let reason, let condition):
            if let release = release {
                recordChecked(release, in: index, status: .skipped, skip: Skip(reason: reason, condition: condition))
            }
            return .skipped(release?.release, reason: reason, condition: condition)
        }
    }

    /// A release the device qualifies for: adopted in place when it carries the running bundle, else announced and taken as far as the
    /// stage goes. A download that adopts answers `UP_TO_DATE`, since nothing waits, and never `UPDATED`, which only a sync answers.
    private func update(to target: IndexRelease, isMandatory: Bool, trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        let release = resolveRelease(target, isMandatory: isMandatory)
        if stage != .check, let current = state.currentRelease, current.bundleId == target.bundleId {
            adoptInPlace(release)
            return stage == .download ? .upToDate(release) : .updated(release, notes: target.notes, installAt: .immediate)
        }
        let strategy = resolveInstallStrategy(isMandatory: isMandatory, options: options)
        if isDownloaded(target) {
            if stage == .check {
                return .available(release, notes: target.notes, downloadBytes: target.sizeBytes)
            }
            let outcome = applyDownloaded(release, notes: target.notes, strategy: strategy)
            return stage == .download ? .downloaded(release, notes: target.notes) : outcome
        }
        listener.updateAvailable(UpdateAvailableEvent(release: release, notes: target.notes, downloadBytes: target.sizeBytes, trigger: trigger))
        switch stage {
        case .check:
            return .available(release, notes: target.notes, downloadBytes: target.sizeBytes)
        case .sync:
            switch options.downloadStrategy ?? configuration.downloadStrategy {
            case .manual:
                return .available(release, notes: target.notes, downloadBytes: target.sizeBytes)
            case .unmetered where loader.isConnectionMetered():
                return .skipped(release, reason: .connectionMetered)
            case .auto, .unmetered:
                return await install(target, isMandatory: isMandatory, strategy: strategy, trigger: trigger, stage: stage, isDownloadForced: false)
            }
        case .download:
            return await install(target, isMandatory: isMandatory, strategy: strategy, trigger: trigger, stage: stage, isDownloadForced: true)
        }
    }

    /// The release as the app sees it: the index's entry with the mandatory flag the evaluation decided, transitive included.
    private func resolveRelease(_ target: IndexRelease, isMandatory: Bool) -> Release {
        return Release(id: target.id, number: target.number, bundleId: target.bundleId, bundleVersion: target.bundleVersion, isMandatory: isMandatory)
    }

    /// A mandatory release follows `mandatoryInstallStrategy`; any other the install strategy.
    private func resolveInstallStrategy(isMandatory: Bool, options: SyncOptions) -> InstallStrategy {
        if isMandatory {
            switch options.mandatoryInstallStrategy ?? configuration.mandatoryInstallStrategy {
            case .immediate: return .immediate
            case .manual: return .manual
            }
        }
        return options.installStrategy ?? configuration.installStrategy
    }

    private func isDownloaded(_ target: IndexRelease) -> Bool {
        guard let next = state.nextRelease, next.bundleId == target.bundleId, let manifest = files.readManifest(bundleId: next.bundleId) else { return false }
        return files.isComplete(manifest, embedded: embedded)
    }

    private func install(_ target: IndexRelease, isMandatory: Bool, strategy: InstallStrategy, trigger: SyncTrigger, stage: Stage, isDownloadForced: Bool) async -> SyncResult {
        let release = resolveRelease(target, isMandatory: isMandatory)
        do {
            let baseBundleId = state.currentRelease?.bundleId ?? configuration.embeddedBundleId
            let outcome = try await downloader.downloadRelease(target, currentBundleId: baseBundleId) { [listener] downloaded, total in
                listener.downloadProgress(releaseId: target.id, downloadedBytes: downloaded, totalBytes: total)
            }
            try BundleProjection.project(outcome.manifest, from: files, embedded: embedded, into: loader.projectionDirectory(bundleId: target.bundleId))
            enqueueDeviceEvent(.downloaded(releaseId: target.id, bundleId: target.bundleId, bytes: outcome.bytes, packKind: outcome.packKind))
        } catch let failure as DownloadFailure {
            enqueueDeviceEvent(.failed(releaseId: target.id, reason: failure.reason.rawValue))
            return .failed(release, reason: failure.reason, message: failure.message)
        } catch {
            enqueueDeviceEvent(.failed(releaseId: target.id, reason: FailedReason.downloadFailed.rawValue))
            return .failed(release, reason: .downloadFailed, message: error.localizedDescription)
        }
        if strategy != .immediate {
            listener.updateDownloaded(UpdateDownloadedEvent(release: release, installAt: strategy, trigger: trigger))
        }
        let outcome = applyDownloaded(release, notes: target.notes, strategy: strategy)
        return stage == .download ? .downloaded(release, notes: target.notes) : outcome
    }

    /// Choosing and applying are two acts: the strategy is a policy over the four functions.
    private func applyDownloaded(_ release: Release, notes: String?, strategy: InstallStrategy) -> SyncResult {
        setNextRelease(release)
        switch strategy {
        case .immediate:
            installNextRelease()
        case .nextStart:
            loader.persistServedBundle(bundleId: release.bundleId)
        case .nextResume, .manual:
            break
        }
        return .updated(release, notes: notes, installAt: strategy)
    }

    /// Rolls the running release back now, even before the app is up; `detail` is the app's own cause, carried on the failure event.
    public func rollbackUpdate(detail: String?) throws {
        if let detail = detail {
            try AttributeRules.validate(value: detail)
        }
        guard state.currentRelease != nil else { return }
        rollbackCurrentRelease(reason: .appRequested, detail: detail)
    }

    /// Back to the embedded bundle, now or, before the app is up in this run, once it is: every downloaded update and the failed list go, the identity stays.
    public func clearUpdates() {
        restartThroughGate(isAskedByApp: true) { [self] in
            stopReadyTimer()
            state.currentRelease = nil
            state.nextRelease = nil
            state.fallbackRelease = nil
            state.failedBundleIds = []
            state.lastRollback = nil
            state.pendingRollbackEvent = nil
            for bundleId in files.bundleIds() {
                loader.deleteProjection(bundleId: bundleId)
            }
            files.deleteEverything()
            loader.persistServedBundle(bundleId: nil)
            reloadApp()
        }
    }

    public func setRestartAllowed(_ allowed: Bool) {
        isRestartAllowed = allowed
        runQueuedRestart()
    }

    // MARK: State

    public func getState() -> StateResult {
        return StateResult(
            currentRelease: state.currentRelease,
            nextRelease: state.nextRelease,
            fallbackRelease: state.fallbackRelease,
            embeddedBundleId: configuration.embeddedBundleId,
            lastCheck: state.lastCheck,
            index: state.cachedIndex.map { IndexState(sequence: $0.body.sequence, fetchedAt: $0.fetchedAt) },
            failedBundleIds: state.failedBundleIds,
            lastReportAt: state.reportedAt)
    }

    public func channel() -> ChannelResult {
        switch state.channel {
        case .id(let id): return ChannelResult(id: id, name: nil, source: .runtime)
        case .name(let name): return ChannelResult(id: resolvedChannelName?.name == name ? resolvedChannelName?.id : nil, name: name, source: .runtime)
        case nil: return ChannelResult(id: configuration.channelId, name: nil, source: .config)
        }
    }

    /// Throws the plain error for an id that is not a UUID: it never reaches a URL, and the stored choice stays.
    public func setChannel(_ choice: ChannelChoice?) throws {
        if case .id(let id) = choice {
            try verifyChannelId(id)
        }
        state.channel = choice
        state.cachedIndex = nil
    }

    /// The channel id a cycle would fetch by, the runtime one or the build's: one stored by an earlier version, or a resource file
    /// written by hand, is refused like the app's own; a name resolves through the channels index, which checks its id there.
    private func verifyChannelId() throws {
        switch state.channel {
        case .id(let id): try verifyChannelId(id)
        case .name: return
        case nil:
            if let id = configuration.channelId {
                try verifyChannelId(id)
            }
        }
    }

    /// A channel id is a UUID, so nothing with `..`, `/` or a query reaches the index's URL.
    private func verifyChannelId(_ id: String) throws {
        guard WireRule.uuid.accepts(id) else {
            throw PlainError("A channel id is a UUID: \(id)")
        }
    }

    public func deviceResult() -> DeviceResult {
        return DeviceResult(id: state.deviceId, platform: device.platform, binaryVersion: device.binaryVersion, binaryBuild: device.binaryBuild, osVersion: device.osVersion, sdkVersion: device.sdkVersion, fingerprint: configuration.fingerprint, channel: channel(), attributes: state.attributes)
    }

    /// Everything the debug screen shows: the device, the configuration, the state and this session's log.
    public func debugSnapshot() -> DebugSnapshot {
        return DebugSnapshot(takenAt: clock.now, device: deviceResult(), configuration: configuration, isDebugBuild: device.isDebugBuild, state: getState(), log: logEntries)
    }

    public func setAttributes(_ changes: [String: String?]) throws {
        var attributes = state.attributes
        for (key, value) in changes {
            if let value = value {
                try AttributeRules.validate(key: key, value: value)
                attributes[key] = value
            } else {
                attributes.removeValue(forKey: key)
            }
        }
        state.attributes = attributes
    }

    // MARK: The four functions and the gate

    /// A restored phone brings the store's keys back without its files: a current or next release with no manifest on disk names a tree that is not there.
    private func hasReleaseWithoutManifest() -> Bool {
        return [state.currentRelease, state.nextRelease].compactMap { $0 }.contains { files.readManifest(bundleId: $0.bundleId) == nil }
    }

    /// A new binary carries a new floor and a restored phone carries no files: the stored releases are forgotten and the embedded bundle runs.
    private func dropStoredReleases() {
        state.currentRelease = nil
        state.nextRelease = nil
        state.fallbackRelease = nil
        state.failedBundleIds = []
        state.lastRollback = nil
        state.pendingRollbackEvent = nil
        state.lastBuiltAt = configuration.builtAt
        loader.persistServedBundle(bundleId: nil)
    }

    private func setNextRelease(_ release: Release) {
        state.nextRelease = release
    }

    /// A downloaded release that has left the cached index since — revoked, or gone from it — is never installed: it is dropped and the served bundle stays the running one.
    private func discardNextReleaseThatLeftTheIndex() {
        guard let next = state.nextRelease, let index = state.cachedIndex?.body, hasLeftIndex(next, index) else { return }
        state.nextRelease = nil
        loader.persistServedBundle(bundleId: state.currentRelease?.bundleId)
    }

    private func hasLeftIndex(_ release: Release, _ index: ChannelIndex) -> Bool {
        return index.revokedReleaseIds.contains(release.id) || !index.releases.contains { $0.id == release.id }
    }

    private func switchToNextRelease() {
        guard let next = state.nextRelease else { return }
        releaseBeforeSwitch = state.currentRelease
        state.currentRelease = next
        state.nextRelease = nil
        loader.persistServedBundle(bundleId: next.bundleId)
        enqueueDeviceEvent(.applied(releaseId: next.id))
    }

    private func loadBundle() {
        let expected = state.currentRelease?.bundleId
        if loader.servedBundleId() != expected {
            loader.loadServedBundle(bundleId: expected)
        }
    }

    /// The restart of the web layer: the bundle loads, a rollback the app has not come up after is announced, then the gate runs; the reloaded app starts again and runs what the state says, so a held restart is moot.
    private func reloadApp() {
        hasStartSettled = false
        queuedRestart = nil
        loader.loadServedBundle(bundleId: state.currentRelease?.bundleId)
        announceRollback()
        if isCurrentReleaseUnconfirmed() {
            startReadyTimer()
        }
    }

    /// The install the SDK performs on its own: the switch and the reload as one act behind the gate, so nothing changes until it runs; the served bundle is the next one already, so the next start switches if this run never does.
    private func installNextRelease() {
        if let next = state.nextRelease {
            loader.persistServedBundle(bundleId: next.bundleId)
        }
        restartThroughGate(isAskedByApp: false) { [self] in
            switchToNextRelease()
            reloadApp()
        }
    }

    /// A restart waits until the app is up in this run, and the SDK's own also while the app holds restarts. One is held at most: the app's replaces a held one, the SDK's yields to it.
    private func restartThroughGate(isAskedByApp: Bool, _ restart: @escaping () -> Void) {
        if isAskedByApp || queuedRestart == nil {
            queuedRestart = QueuedRestart(isAskedByApp: isAskedByApp, restart: restart)
        }
        runQueuedRestart()
    }

    private func runQueuedRestart() {
        guard let queued = queuedRestart, hasStartSettled, isRestartAllowed || queued.isAskedByApp else { return }
        queuedRestart = nil
        queued.restart()
    }

    /// The app is up in this run: a rollback announced to it is delivered, and the restart held for it runs.
    private func settleStart() {
        hasStartSettled = true
        if hasAnnouncedRollback {
            hasAnnouncedRollback = false
            state.pendingRollbackEvent = nil
        }
        runQueuedRestart()
    }

    /// The stored notice reaches the JavaScript that just started, once per start; it stays stored until the app is up after it.
    private func announceRollback() {
        guard let event = state.pendingRollbackEvent else { return }
        hasAnnouncedRollback = true
        listener.rolledBack(event)
    }

    private func adoptInPlace(_ release: Release) {
        let wasConfirmed = !isCurrentReleaseUnconfirmed()
        state.currentRelease = release
        if wasConfirmed {
            state.fallbackRelease = release
        }
        loader.persistServedBundle(bundleId: release.bundleId)
    }

    private func isCurrentReleaseUnconfirmed() -> Bool {
        guard let current = state.currentRelease else { return false }
        return current.bundleId != state.fallbackRelease?.bundleId
    }

    private func confirmCurrentRelease() {
        stopReadyTimer()
        if let current = state.currentRelease, isCurrentReleaseUnconfirmed() {
            state.fallbackRelease = current
            enqueueDeviceEvent(.confirmed(releaseId: current.id))
        }
        if isStartSyncPending {
            isStartSyncPending = false
            if configuration.autoCheck {
                startAutomaticCycle(trigger: .start)
            }
        }
    }

    /// A rollback never waits for the app to be up: the app's own and the crash a start finds reload at once, the timer's, which settles the start, waits only while the app holds restarts.
    private func rollbackCurrentRelease(reason: RollbackReason, detail: String?) {
        guard let current = state.currentRelease else { return }
        stopReadyTimer()
        state.failedBundleIds = Array(Set(state.failedBundleIds + [current.bundleId])).sorted()
        let fallback = resolveFallbackRelease()
        state.currentRelease = fallback
        state.nextRelease = nil
        state.lastRollback = LastRollback(from: current, to: fallback, reason: reason)
        state.pendingRollbackEvent = RolledBackEvent(from: current, to: fallback, reason: reason)
        hasAnnouncedRollback = false
        enqueueDeviceEvent(.failed(releaseId: current.id, reason: reason.rawValue, detail: detail))
        enqueueDeviceEvent(.rolledBack(fromReleaseId: current.id, toReleaseId: fallback?.id))
        loader.persistServedBundle(bundleId: fallback?.bundleId)
        switch reason {
        case .appCrashed, .appRequested:
            reloadApp()
        case .readinessTimedOut:
            restartThroughGate(isAskedByApp: false) { [self] in reloadApp() }
        }
    }

    /// The release to fall back to right now: the last confirmed one while it can still run, else the embedded bundle.
    private func resolveFallbackRelease() -> Release? {
        guard let fallback = state.fallbackRelease,
              !state.failedBundleIds.contains(fallback.bundleId),
              !(state.cachedIndex?.body.revokedReleaseIds.contains(fallback.id) ?? false),
              let manifest = files.readManifest(bundleId: fallback.bundleId),
              files.isComplete(manifest, embedded: embedded) else {
            return nil
        }
        return fallback
    }

    private func revertToEmbedded() {
        stopReadyTimer()
        state.currentRelease = nil
        state.nextRelease = nil
        loader.persistServedBundle(bundleId: nil)
        restartThroughGate(isAskedByApp: false) { [self] in reloadApp() }
    }

    /// The readiness window runs in the foreground alone: a gate armed in the background waits for the resume.
    private func startReadyTimer() {
        stopReadyTimer()
        guard backgroundedAt == nil else {
            isReadyTimerPaused = true
            return
        }
        readyTimer = scheduler.schedule(after: configuration.readyTimeout) { [weak self] in
            await self?.handleReadyTimeout()
        }
    }

    private func stopReadyTimer() {
        readyTimer?.cancel()
        readyTimer = nil
        isReadyTimerPaused = false
    }

    private func pauseReadyTimer() {
        guard readyTimer != nil else { return }
        stopReadyTimer()
        isReadyTimerPaused = true
    }

    /// The full window starts again: the time already spent in the foreground counts for nothing, as the time in the background does.
    private func resumeReadyTimer() {
        guard isReadyTimerPaused else { return }
        startReadyTimer()
    }

    /// The timeout settles the start before the rollback, so a restart held for the start runs as the reload to the fallback, after the rollback has dropped the release it would switch to.
    /// A timeout that fires as the timer stops, paused or confirmed, is ignored.
    func handleReadyTimeout() {
        guard readyTimer != nil, isCurrentReleaseUnconfirmed() else { return }
        hasStartSettled = true
        rollbackCurrentRelease(reason: .readinessTimedOut, detail: nil)
    }

    private func scheduleIntervalSync(after seconds: TimeInterval) {
        intervalTimer?.cancel()
        guard configuration.autoCheck else { return }
        intervalTimer = scheduler.schedule(after: seconds) { [weak self] in
            await self?.startAutomaticCycle(trigger: .interval)
        }
    }

    /// Everything no kept release lists: the served tree of every other bundle first, since its links hold the bytes.
    private func deleteUnusedFiles() {
        let kept = Set([state.currentRelease, state.nextRelease, state.fallbackRelease].compactMap { $0?.bundleId })
        for bundleId in files.bundleIds() where !kept.contains(bundleId) {
            loader.deleteProjection(bundleId: bundleId)
        }
        files.deleteUnusedFiles(keepingBundleIds: kept)
    }

    // MARK: The index

    enum IndexFetch {
        case index(ChannelIndex)
        case offline
        case invalid(String)
        case absent
        /// The channel set at runtime serves no index: the choice is cleared and the cycle falls back to the build's own channel.
        case gone
    }

    /// The runtime choice, then the configured id; a name resolves through the channels index, offline being offline and not an unknown name.
    private func resolveChannelId() async -> ChannelResolution {
        switch state.channel {
        case nil: return configuration.channelId.map { .id($0) } ?? .missing
        case .id(let id): return .id(id)
        case .name(let name):
            if let resolved = resolvedChannelName, resolved.name == name { return .id(resolved.id) }
            guard let url = URL(string: "\(configuration.filesBaseUrl)/apps/\(configuration.appId)/channels/v1/index.json") else {
                return .invalid("Invalid channels index URL")
            }
            guard let response = try? await http.get(url, headers: [:]) else { return .offline }
            switch response.status {
            case 200:
                guard let index = try? Json.decoder.decode(ChannelsIndex.self, from: response.body) else {
                    return .invalid("The channels index could not be parsed")
                }
                guard let entry = index.channels.first(where: { $0.name == name }) else { return .unknown }
                guard WireRule.uuid.accepts(entry.id) else {
                    return .invalid("The channels index names the channel \(name) by an id that is not a UUID")
                }
                resolvedChannelName = (name, entry.id)
                return .id(entry.id)
            case 404:
                return .unknown
            default:
                return .offline
            }
        }
    }

    /// A device has a channel when the app set one at runtime or the build carries one.
    private var hasChannel: Bool {
        return state.channel != nil || configuration.channelId != nil
    }

    private func fetchChannelIndex(channelId: String) async -> IndexFetch {
        guard let url = URL(string: "\(configuration.filesBaseUrl)/apps/\(configuration.appId)/channels/\(channelId)/\(device.platform)/v1/index.json") else {
            return .invalid("Invalid index URL")
        }
        let cached = state.cachedIndex.flatMap { $0.body.channelId == channelId ? $0 : nil }
        var headers: [String: String] = [:]
        if let etag = cached?.etag {
            headers["If-None-Match"] = etag
        }
        guard let response = try? await http.get(url, headers: headers) else {
            return cached.map { .index($0.body) } ?? .offline
        }
        switch response.status {
        case 304:
            guard let cached = cached else { return .offline }
            state.cachedIndex = CachedIndex(etag: cached.etag, fetchedAt: clock.now, body: cached.body)
            return .index(cached.body)
        case 200:
            guard let index = try? Json.decoder.decode(ChannelIndex.self, from: response.body) else {
                return .invalid("The channel index could not be parsed")
            }
            guard index.appId == configuration.appId, index.channelId == channelId, index.platform == device.platform else {
                return .invalid("The channel index names another app, channel or platform")
            }
            if let cached = cached, index.sequence < cached.body.sequence {
                return .index(cached.body)
            }
            state.cachedIndex = CachedIndex(etag: response.header("ETag"), fetchedAt: clock.now, body: index)
            return .index(index)
        case 404:
            if case .some = state.channel { return .gone }
            return .absent
        default:
            return cached.map { .index($0.body) } ?? .offline
        }
    }

    /// Live updates are off in a build that embeds no bundle, and in a debug build that has them disabled: every cycle skips with `BUILD_DEBUG`.
    private var isDisabledInThisBuild: Bool {
        return configuration.embeddedBundleManifest == nil || (device.isDebugBuild && !configuration.enabledInDebugBuilds)
    }

    private func deviceInfo() -> DeviceInfo {
        return DeviceInfo(attributes: state.attributes, binaryBuild: device.binaryBuild, binaryVersion: device.binaryVersion, builtAt: configuration.builtAt, currentRelease: state.currentRelease, deviceId: state.deviceId, failedBundleIds: state.failedBundleIds, fingerprint: configuration.fingerprint, osVersion: device.osVersion, reportedAt: state.reportedAt)
    }

    // MARK: Events

    private func recordChecked(_ release: IndexRelease, in index: ChannelIndex, status: SyncStatus, skip: Skip?) {
        var checked = state.checkedReleaseIds.filter { id in index.releases.contains { $0.id == id } }
        guard !checked.contains(release.id) else {
            state.checkedReleaseIds = checked
            return
        }
        checked.append(release.id)
        state.checkedReleaseIds = checked
        enqueueDeviceEvent(.checked(releaseId: release.id, status: status, reason: skip?.reason, condition: skip?.condition))
    }

    private func enqueueDeviceEvent(_ event: DeviceEvent) {
        state.unsentEvents = Array((state.unsentEvents + [event]).suffix(DeviceEventsRequest.maximumEventCount))
        if isSendingDeviceEvents {
            eventCountEnqueuedInFlight += 1
        }
        if let entry = LogEntry.ofDeviceEvent(event, at: clock.now) {
            record(entry)
        }
    }

    private func record(_ entry: LogEntry) {
        logEntries = Array((logEntries + [entry]).suffix(LogEntry.capacity))
    }

    /// One batch to the events endpoint, the outbox as it stands and the report when it changed and the endpoint reads it: a readable 202 takes both,
    /// a refusal drops the events and leaves the report unacknowledged, anything else keeps both for the next sync.
    private func sendDeviceEvents() async {
        guard !isSendingDeviceEvents, !isDisabledInThisBuild else { return }
        let events = state.unsentEvents
        var report = buildDeviceReport()
        if report?.isReadable == false {
            record(LogEntry(at: clock.now, code: "REPORT_UNREADABLE", message: "the device report stays unsent: a fact or an attribute is one the events endpoint refuses"))
            report = nil
        }
        guard !events.isEmpty || report != nil else { return }
        let request = DeviceEventsRequest(deviceId: state.deviceId, events: events, platform: device.platform, report: report, sdkVersion: device.sdkVersion)
        guard request.isReadable else {
            record(LogEntry(at: clock.now, code: "REPORT_UNREADABLE", message: "\(events.count) events kept: the SDK's version or the platform is one the events endpoint refuses"))
            return
        }
        guard let url = URL(string: "\(configuration.updatesBaseUrl)/v1/apps/\(configuration.appId)/events"),
              let body = try? Json.encoder.encode(request) else { return }
        isSendingDeviceEvents = true
        eventCountEnqueuedInFlight = 0
        defer { isSendingDeviceEvents = false }
        let answer = BatchAnswer(try? await http.post(url, headers: ["Content-Type": "application/json"], body: body))
        record(LogEntry.ofBatch(answer, eventCount: events.count, at: clock.now))
        switch answer {
        case .acknowledged(let reportedAt):
            dropBatchEvents()
            state.reportedAt = reportedAt
            if let report = report {
                state.acknowledgedReport = report
            }
        case .refused:
            dropBatchEvents()
        case .failed:
            break
        }
    }

    /// The batch's events leave the outbox: what stays is exactly what was enqueued while the batch was on its way, the newest 200 of it,
    /// also when the outbox's cap dropped events of the batch meanwhile.
    private func dropBatchEvents() {
        state.unsentEvents = Array(state.unsentEvents.suffix(eventCountEnqueuedInFlight))
    }

    /// The facts the server should hold: the report when they differ from the acknowledged ones or the month began, else nothing.
    /// A device without a channel — a runtime name not yet resolved, a build that carries none — reports nothing: a row for it would mislead.
    private func buildDeviceReport() -> DeviceReport? {
        let channel = channel()
        guard let channelId = channel.id else { return nil }
        let report = DeviceReport(attributes: state.attributes, binaryBuild: device.binaryBuild, binaryVersion: device.binaryVersion, channelId: channelId, channelSource: channel.source, embeddedBundleId: configuration.embeddedBundleId, fingerprint: configuration.fingerprint, osVersion: device.osVersion, releaseId: state.currentRelease?.id)
        if report == state.acknowledgedReport, let reportedAt = state.reportedAt, resolveMonth(of: reportedAt) == resolveMonth(of: clock.now) {
            return nil
        }
        return report
    }

    private func resolveMonth(of date: Date) -> String {
        return String(Iso8601.format(date).prefix(7))
    }
}

/// The start's answer handed from the core's task to the host's waiting thread.
private final class StartAnswer: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var bundleId: String??

    func resolve(_ bundleId: String?) {
        lock.lock()
        self.bundleId = .some(bundleId)
        lock.unlock()
        semaphore.signal()
    }

    /// The answer, `nil` when none came within the timeout.
    func wait(timeout: TimeInterval) -> String?? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return bundleId
    }
}
