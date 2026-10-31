import Foundation

/// The state machine every framework shares: three named releases, a readiness gate and one cycle of three stages.
public actor Core {
    // A call joins a running cycle of its own stage only, so each call answers with its own result type.
    enum Stage {
        case check, download, sync
    }

    private struct QueuedRestart {
        let isAskedByApp: Bool
        let restart: () -> Void
    }

    enum ChannelResolution {
        case id(String)
        case offline
        case unknown
        case invalid(String)
        // The build carries no channel and the app set none at runtime.
        case missing
    }

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
    private let applicationState: ApplicationState
    private let network: NetworkState

    private var readyTimer: ScheduledTask?
    private var isReadyTimerPaused = false
    private var intervalTimer: ScheduledTask?
    // One cycle at a time, so no two stages ever download side by side.
    private var runningCycle: (stage: Stage, task: Task<SyncResult, Never>)?
    private var isRestartAllowed = true
    private var queuedRestart: QueuedRestart?
    // Set by the first render, `notifyReady()` or the readiness timeout. Every reload the core performs clears it.
    private var hasStartSettled = false
    // A readiness signal reported before the latest load belongs to the replaced bundle.
    nonisolated let bundleLoadCount = BundleLoadCount()
    private var isStartSyncPending = false
    private var isSendingDeviceEvents = false
    // Events enqueued while a batch is in flight are not part of it, so they stay in the outbox whatever the answer.
    private var eventCountEnqueuedInFlight = 0
    private var backgroundedAt: Date?
    private var resolvedChannelName: (name: String, id: String)?
    private var hasAnnouncedRollback = false
    // Answered once as the `previousRelease` of `notifyReady()`.
    private var releaseBeforeSwitch: Release?
    private var logEntries: [LogEntry] = []
    private var backgroundWork: [UUID: Task<Void, Never>] = [:]
    // Every cycle waits for this cleanup, since a download writes files no kept release lists yet.
    private var unusedFilesDeletion: Task<Void, Never>?

    /// Creates the core. The defaults are the production wiring every SDK on iOS uses; tests replace them.
    public init(configuration: Configuration, device: DeviceFacts, store: KeyValueStore = UserDefaultsStore(), files: FileStore = FileStore(rootDirectory: FileStore.defaultRootDirectory), embedded: EmbeddedBundle, http: HttpClient = UrlSessionHttpClient(), loader: BundleLoader, listener: CoreListener, scheduler: Scheduler = DispatchScheduler(), clock: Clock = SystemClock(), applicationState: ApplicationState = SystemApplicationState(), network: NetworkState = NetworkMonitor(), temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.configuration = configuration
        self.device = device
        self.state = StateStore(store: store)
        self.files = files
        self.embedded = embedded
        self.downloader = Downloader(configuration: configuration, platform: device.platform, files: files, embedded: embedded, http: http, clock: clock, temporaryDirectory: temporaryDirectory)
        self.http = http
        self.loader = loader
        self.listener = listener
        self.scheduler = scheduler
        self.clock = clock
        self.applicationState = applicationState
        self.network = network
    }

    /// The longest `handleAppStartBlocking` waits for an answer before it serves the embedded bundle.
    public static let startTimeout: TimeInterval = 2
    // Past this age, a fetched index replaces the kept one whatever its sequence.
    // A forged far-future sequence then freezes a device for a day at most.
    static let cachedIndexMaxAge: TimeInterval = 24 * 60 * 60

    /// Runs the start of the app and answers the bundle to serve, `nil` for the embedded one.
    /// It never awaits the network: the check and the cleanup run after it returns.
    /// A headless start, for a host that will render no screen, applies no waiting release, arms no readiness gate and loads nothing.
    @discardableResult
    public func handleAppStart(isHeadless: Bool = false) async -> String? {
        let isInForeground = await MainActor.run { applicationState.isInForeground }
        return handleAppStart(isHeadless: isHeadless, isInForeground: isInForeground)
    }

    private func handleAppStart(isHeadless: Bool, isInForeground: Bool) -> String? {
        if !isInForeground {
            backgroundedAt = clock.now
        }
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
        if !isHeadless {
            if let next = state.nextRelease, shouldSwitchAtStart(to: next) {
                switchToNextRelease()
            }
            loadBundle()
        }
        if !hasAnnouncedRollback {
            announceRollback()
        }
        if isCurrentReleaseUnconfirmed() {
            startReadyTimer()
            isStartSyncPending = true
        } else if configuration.checkStrategy == .auto {
            startAutomaticCycle(trigger: .start)
        }
        unusedFilesDeletion = startBackgroundWork { self.deleteUnusedFiles() }
        return resolveServedBundleId(of: state.currentRelease)
    }

    /// `handleAppStart()` for a host that resolves its bundle in synchronous code, waiting at most `startTimeout`.
    /// Without an answer in time it answers the embedded bundle, and the start reloads the host into the right one once it runs.
    /// It is safe to call on the main thread.
    public nonisolated func handleAppStartBlocking(isHeadless: Bool = false) -> String? {
        return handleAppStartBlocking(isHeadless: isHeadless, timeout: Core.startTimeout)
    }

    nonisolated func handleAppStartBlocking(isHeadless: Bool = false, timeout: TimeInterval) -> String? {
        let answer = StartAnswer()
        let isInForeground = Thread.isMainThread ? applicationState.isInForeground : nil
        Task.detached(priority: .userInitiated) {
            if let isInForeground = isInForeground {
                answer.resolve(await self.handleAppStart(isHeadless: isHeadless, isInForeground: isInForeground))
            } else {
                answer.resolve(await self.handleAppStart(isHeadless: isHeadless))
            }
        }
        return answer.wait(timeout: timeout) ?? nil
    }

    // An `immediate` apply this run never got to also switches here. `next_resume` and `manual` wait across starts.
    private func shouldSwitchAtStart(to next: NextRelease) -> Bool {
        if loader.servedBundleId() == resolveServedBundleId(of: next.release) { return true }
        return next.applyStrategy == .nextStart || next.applyStrategy == .immediate
    }

    /// Reports the first render, which settles the start and is the readiness signal when `readySignal` is `render`.
    /// A render reported before the core last loaded a bundle belongs to the replaced bundle and counts for nothing.
    public nonisolated func handleRendered() async {
        await handleRendered(bundleLoadCountAtSignal: bundleLoadCount.value)
    }

    func handleRendered(bundleLoadCountAtSignal: Int) {
        guard !hasLoadedBundle(since: bundleLoadCountAtSignal) else { return }
        if configuration.readySignal == .render {
            confirmCurrentRelease()
        }
        settleStart()
    }

    /// Ends the readiness gate when `readySignal` is `manual`, settles the start and tells once whether a rollback or a switch came before.
    /// A call from a bundle the core has since replaced changes nothing and answers the running release.
    public nonisolated func notifyReady() async -> NotifyReadyResult {
        await notifyReady(bundleLoadCountAtSignal: bundleLoadCount.value)
    }

    func notifyReady(bundleLoadCountAtSignal: Int) -> NotifyReadyResult {
        guard !hasLoadedBundle(since: bundleLoadCountAtSignal) else {
            return NotifyReadyResult(currentRelease: state.currentRelease, previousRelease: nil, isRolledBack: false, rollbackReason: nil)
        }
        confirmCurrentRelease()
        let rollback = state.lastRollback
        state.lastRollback = nil
        let previousRelease = rollback?.fromRelease ?? releaseBeforeSwitch
        releaseBeforeSwitch = nil
        let result = NotifyReadyResult(currentRelease: state.currentRelease, previousRelease: previousRelease, isRolledBack: rollback != nil, rollbackReason: rollback?.reason)
        settleStart()
        return result
    }

    /// Handles the move to the background: stops the interval and readiness timers and notes the time for `next_resume`.
    public func handleAppPause() {
        backgroundedAt = clock.now
        intervalTimer?.cancel()
        intervalTimer = nil
        pauseReadyTimer()
    }

    /// Handles the return to the foreground.
    /// Restarts a paused readiness window, applies a `next_resume` release after enough time away, else checks once the interval has passed.
    public func handleAppResume() {
        let backgroundDuration = backgroundedAt.map { clock.now.timeIntervalSince($0) }
        backgroundedAt = nil
        resumeReadyTimer()
        discardNextReleaseThatLeftTheIndex()
        if let duration = backgroundDuration, state.nextRelease?.applyStrategy == .nextResume, duration >= configuration.nextResumeMinimumBackgroundSeconds {
            restartIntoNextRelease()
            return
        }
        guard configuration.checkStrategy == .auto else { return }
        if let elapsed = state.lastSyncAt.map({ clock.now.timeIntervalSince($0) }), elapsed < configuration.checkIntervalSeconds {
            scheduleIntervalSync(after: configuration.checkIntervalSeconds - elapsed)
        } else {
            startAutomaticCycle(trigger: .resume)
        }
    }

    // A device without a channel starts no cycle, since it could only fail.
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

    // Tests wait on this instead of a sleep. It also waits for work started meanwhile.
    func waitForBackgroundWork() async {
        while let work = backgroundWork.values.first {
            await work.value
        }
    }

    /// Runs one full cycle, or joins the one that runs.
    /// Throws a plain error before any fetch when the channel id in effect is not a UUID; so do the other two stages.
    public func sync(trigger: SyncTrigger, options: SyncOptions = SyncOptions()) async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: trigger, stage: .sync, options: options)
    }

    /// `sync()` with the download gate shut: it downloads and applies nothing.
    /// A downloaded release answers `available`, and a release that carries the running bundle is adopted.
    public func checkForUpdate() async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: .manual, stage: .check, options: SyncOptions(downloadStrategy: .manual))
    }

    /// `sync()` with the download gate open: it re-checks the index, then downloads and applies per the apply strategies.
    /// It never answers `available`.
    public func downloadUpdate(options: DownloadUpdateOptions = DownloadUpdateOptions()) async throws -> SyncResult {
        try verifyChannelId()
        return await runCycle(trigger: .manual, stage: .download, options: SyncOptions(applyStrategy: options.applyStrategy, downloadStrategy: .auto, mandatoryApplyStrategy: options.mandatoryApplyStrategy))
    }

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

    /// Applies the downloaded update and reloads the app, at once or, before the app is up in this run, once it is.
    public func applyUpdate() -> ApplyUpdateResult {
        discardNextReleaseThatLeftTheIndex()
        guard let next = state.nextRelease else {
            return ApplyUpdateResult(status: .nothingToApply, release: state.currentRelease)
        }
        restartThroughGate(isAskedByApp: true) { [self] in applyNextRelease() }
        return ApplyUpdateResult(status: .applied, release: next.release)
    }

    private func performCycle(trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        let result = await resolveCycle(trigger: trigger, stage: stage, options: options)
        state.lastCheck = LastCheck(checkedAt: clock.now, trigger: trigger, result: result)
        if stage == .sync {
            state.lastSyncAt = clock.now
            scheduleIntervalSync(after: configuration.checkIntervalSeconds)
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
            return .skipped(nil, reason: .buildDebug)
        }
        let channelId: String
        switch await resolveChannelId() {
        case .id(let id): channelId = id
        case .offline: return .failed(nil, reason: .deviceOffline, message: "The channels index could not be fetched to resolve the channel name")
        case .unknown: return .failed(nil, reason: .channelUnknown, message: "The channel set at runtime is not in the app's channels index")
        case .invalid(let message): return .failed(nil, reason: .indexInvalid, message: message)
        case .missing: return .failed(nil, reason: .channelUnknown, message: Core.missingChannelMessage)
        }
        let index: ChannelIndex
        switch await fetchChannelIndex(channelId: channelId) {
        case .index(let fetched): index = fetched
        case .offline: return .failed(nil, reason: .deviceOffline, message: "The channel index could not be fetched and no cached copy exists")
        case .invalid(let message): return .failed(nil, reason: .indexInvalid, message: message)
        case .absent: return .upToDate(current)
        case .gone:
            state.channel = nil
            return await resolveCycle(trigger: trigger, stage: stage, options: options)
        }
        switch Evaluator.evaluation(of: index, device: deviceInfo()).outcome {
        case .upToDate:
            return .upToDate(current)
        case .available(let target, let isMandatory):
            recordChecked(target, in: index, status: .available)
            return await update(to: target, isMandatory: isMandatory, trigger: trigger, stage: stage, options: options)
        case .skipped(let release, .releaseRevoked, _):
            if (release?.bundleId ?? configuration.embeddedBundleId) == runningBundleId {
                adoptInPlace(release?.release)
                return .skipped(release?.release, reason: .releaseRevoked)
            }
            if stage == .check {
                return .skipped(release?.release, reason: .releaseRevoked)
            }
            guard let target = release else {
                revertToEmbedded()
                return .skipped(nil, reason: .releaseRevoked)
            }
            let outcome = await downloadAndApply(target, isMandatory: true, strategy: .immediate, trigger: trigger)
            return outcome.status == .failed ? outcome : .skipped(target.release, reason: .releaseRevoked)
        case .skipped(let release, let reason, let conditionType):
            if let release = release {
                recordChecked(release, in: index, status: .skipped, reason: reason, conditionType: conditionType)
            }
            return .skipped(release?.release, reason: reason, conditionType: conditionType)
        }
    }

    // An adoption answers `up_to_date`, since nothing waits and nothing reloads.
    // The strategy stored with a downloaded release wins over the configuration, so an automatic cycle never overrides the app.
    private func update(to target: IndexRelease, isMandatory: Bool, trigger: SyncTrigger, stage: Stage, options: SyncOptions) async -> SyncResult {
        let release = resolveRelease(target, isMandatory: isMandatory)
        if target.bundleId == runningBundleId {
            adoptInPlace(release)
            return .upToDate(release)
        }
        let requestedStrategy = resolveRequestedApplyStrategy(isMandatory: isMandatory, options: options)
        let downloadSizeBytes = isCarryingEmbeddedBundle(release) ? 0 : target.sizeBytes
        if let downloaded = readDownloadedRelease(target) {
            if stage == .check {
                return .available(release, notes: target.notes, downloadSizeBytes: downloadSizeBytes)
            }
            return applyDownloaded(release, notes: target.notes, strategy: requestedStrategy ?? downloaded.applyStrategy)
        }
        let strategy = requestedStrategy ?? resolveConfiguredApplyStrategy(isMandatory: isMandatory)
        listener.updateAvailable(UpdateAvailableEvent(release: release, notes: target.notes, downloadSizeBytes: downloadSizeBytes, trigger: trigger))
        switch resolveDownloadStrategy(of: release, stage: stage, options: options) {
        case .manual:
            return .available(release, notes: target.notes, downloadSizeBytes: downloadSizeBytes)
        case .unmetered where network.isConnectionMetered():
            return .skipped(release, reason: .connectionMetered)
        case .auto, .unmetered:
            return await downloadAndApply(target, isMandatory: isMandatory, strategy: strategy, trigger: trigger)
        }
    }

    // A release of the embedded bundle downloads nothing, so it passes every gate but the check's.
    private func resolveDownloadStrategy(of release: Release, stage: Stage, options: SyncOptions) -> DownloadStrategy {
        return isCarryingEmbeddedBundle(release) && stage != .check ? .auto : options.downloadStrategy ?? configuration.downloadStrategy
    }

    // The mandatory flag is the evaluation's, transitive included.
    private func resolveRelease(_ target: IndexRelease, isMandatory: Bool) -> Release {
        return Release(id: target.id, number: target.number, bundleId: target.bundleId, bundleVersion: target.bundleVersion, isMandatory: isMandatory)
    }

    private func resolveRequestedApplyStrategy(isMandatory: Bool, options: SyncOptions) -> ApplyStrategy? {
        return isMandatory ? options.mandatoryApplyStrategy.map(ApplyStrategy.init) : options.applyStrategy
    }

    private func resolveConfiguredApplyStrategy(isMandatory: Bool) -> ApplyStrategy {
        return isMandatory ? ApplyStrategy(configuration.mandatoryApplyStrategy) : configuration.applyStrategy
    }

    private func readDownloadedRelease(_ target: IndexRelease) -> NextRelease? {
        guard let next = state.nextRelease, next.release.bundleId == target.bundleId, hasEveryFile(of: next.release) else { return nil }
        return next
    }

    private func downloadAndApply(_ target: IndexRelease, isMandatory: Bool, strategy: ApplyStrategy, trigger: SyncTrigger) async -> SyncResult {
        let release = resolveRelease(target, isMandatory: isMandatory)
        do {
            if !isCarryingEmbeddedBundle(release) {
                try await downloadBundle(of: target)
            }
        } catch let failure as DownloadFailure {
            enqueueDeviceEvent(.failed(releaseId: target.id, reason: failure.reason.rawValue))
            return .failed(release, reason: failure.reason, message: failure.message)
        } catch {
            enqueueDeviceEvent(.failed(releaseId: target.id, reason: FailedReason.downloadFailed.rawValue))
            return .failed(release, reason: .downloadFailed, message: error.localizedDescription)
        }
        if strategy != .immediate {
            listener.updateDownloaded(UpdateDownloadedEvent(release: release, applyStrategy: strategy, trigger: trigger))
        }
        return applyDownloaded(release, notes: target.notes, strategy: strategy)
    }

    private func downloadBundle(of target: IndexRelease) async throws {
        let outcome = try await downloader.downloadRelease(target, baseBundleId: runningBundleId) { [listener] progressBytes, downloadSizeBytes in
            listener.downloadProgress(DownloadProgressEvent(downloadSizeBytes: downloadSizeBytes, progressBytes: progressBytes, releaseId: target.id))
        }
        try BundleProjection.project(outcome.manifest, from: files, embedded: embedded, into: loader.projectionDirectory(bundleId: target.bundleId))
        enqueueDeviceEvent(.downloaded(releaseId: target.id, downloadSizeBytes: outcome.downloadSizeBytes, packKind: outcome.packKind))
    }

    // The apply moment is stored with the release, so the start and the resume read it, never the configuration.
    private func applyDownloaded(_ release: Release, notes: String?, strategy: ApplyStrategy) -> SyncResult {
        setNextRelease(NextRelease(release: release, applyStrategy: strategy))
        switch strategy {
        case .immediate:
            restartIntoNextRelease()
            return .applied(release, notes: notes)
        case .nextStart:
            persistServedBundle(of: release)
        case .nextResume, .manual:
            break
        }
        return .downloaded(release, notes: notes, applyStrategy: strategy)
    }

    /// Rolls the running release back and reloads at once, even before the app is up.
    /// `detail` is the app's own cause, sent with the failure event. The embedded bundle has nothing to roll back to.
    public func rollbackUpdate(detail: String?) throws {
        if let detail = detail {
            try AttributeRules.validate(value: detail)
        }
        guard let current = state.currentRelease, !isCarryingEmbeddedBundle(current) else { return }
        rollbackCurrentRelease(reason: .appRequested, detail: detail)
        reloadApp()
    }

    /// Drops every downloaded update and the failed list and reloads into the embedded bundle; the device identity stays.
    /// Before the app is up in this run, the whole call waits until it is, the deletion included.
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
            persistServedBundle(of: nil)
            reloadApp()
        }
    }

    public func setRestartAllowed(_ isAllowed: Bool) {
        isRestartAllowed = isAllowed
        runQueuedRestart()
    }

    public func getState() -> GetStateResult {
        return GetStateResult(
            currentRelease: state.currentRelease,
            nextRelease: state.nextRelease?.release,
            fallbackRelease: state.fallbackRelease,
            embeddedBundleId: configuration.embeddedBundleId,
            lastCheck: state.lastCheck,
            index: state.cachedIndex.map { IndexState(sequence: $0.body.sequence, fetchedAt: $0.fetchedAt) },
            failedBundleIds: state.failedBundleIds,
            reportedAt: state.reportedAt)
    }

    public func getChannel() -> GetChannelResult {
        switch state.channel {
        case .id(let id): return GetChannelResult(id: id, name: nil, source: .runtime)
        case .name(let name): return GetChannelResult(id: resolvedChannelName?.name == name ? resolvedChannelName?.id : nil, name: name, source: .runtime)
        case nil: return GetChannelResult(id: configuration.channelId, name: nil, source: .config)
        }
    }

    /// Sets or clears the channel chosen at runtime.
    /// Throws a plain error for an id that is not a UUID, and the stored choice then stays.
    public func setChannel(_ choice: ChannelChoice?) throws {
        if case .id(let id) = choice {
            try verifyChannelId(id)
        }
        state.channel = choice
        state.cachedIndex = nil
    }

    // An id stored by an earlier version or written by hand into the resource file is refused like the app's own.
    // A channel name is checked where the channels index resolves it.
    private func verifyChannelId() throws {
        if let id = getChannel().id {
            try verifyChannelId(id)
        }
    }

    // A UUID keeps `..`, `/` and a query out of the index URL.
    private func verifyChannelId(_ id: String) throws {
        guard WireRule.uuid.accepts(id) else {
            throw PlainError("A channel id is a UUID: \(id)")
        }
    }

    public func getDevice() -> GetDeviceResult {
        return GetDeviceResult(id: state.deviceId, platform: device.platform, binaryVersion: device.binaryVersion, binaryBuild: device.binaryBuild, osVersion: device.osVersion, sdkVersion: device.sdkVersion, fingerprint: configuration.fingerprint, channel: getChannel(), attributes: state.attributes)
    }

    /// Everything the debug screen shows: the device, the configuration, the state and this session's log.
    public func debugSnapshot() -> DebugSnapshot {
        return DebugSnapshot(takenAt: clock.now, device: getDevice(), configuration: configuration, isDebugBuild: device.isDebugBuild, state: getState(), log: logEntries)
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

    // A restored phone brings back the stored keys without the files.
    private func hasReleaseWithoutManifest() -> Bool {
        return [state.currentRelease, state.nextRelease?.release].compactMap { $0 }.contains { !isCarryingEmbeddedBundle($0) && files.readManifest(bundleId: $0.bundleId) == nil }
    }

    // Dropping the kept index and its ETag makes the first check fetch unconditionally.
    // So a store update heals a device that a far-future sequence froze.
    private func dropStoredReleases() {
        state.cachedIndex = nil
        state.currentRelease = nil
        state.nextRelease = nil
        state.fallbackRelease = nil
        state.failedBundleIds = []
        state.lastRollback = nil
        state.pendingRollbackEvent = nil
        state.lastBuiltAt = configuration.builtAt
        persistServedBundle(of: nil)
    }

    private func setNextRelease(_ next: NextRelease) {
        state.nextRelease = next
    }

    private func discardNextReleaseThatLeftTheIndex() {
        guard let next = state.nextRelease, let index = state.cachedIndex?.body, hasLeftIndex(next.release, index) else { return }
        state.nextRelease = nil
        persistServedBundle(of: state.currentRelease)
    }

    private func hasLeftIndex(_ release: Release, _ index: ChannelIndex) -> Bool {
        return index.revokedReleaseIds.contains(release.id) || !index.releases.contains { $0.id == release.id }
    }

    // The release stays unconfirmed, so the reload that follows runs the readiness gate.
    // The embedded bundle is never gated, so it is never rolled back or blocklisted.
    private func switchToNextRelease() {
        guard let next = state.nextRelease?.release else { return }
        releaseBeforeSwitch = state.currentRelease
        state.currentRelease = next
        state.nextRelease = nil
        persistServedBundle(of: next)
        enqueueDeviceEvent(.applied(releaseId: next.id))
        if isCarryingEmbeddedBundle(next) {
            confirmCurrentRelease()
        }
    }

    private var runningBundleId: String? {
        return state.currentRelease?.bundleId ?? configuration.embeddedBundleId
    }

    private func isCarryingEmbeddedBundle(_ release: Release) -> Bool {
        return release.bundleId == configuration.embeddedBundleId
    }

    // A release of the embedded bundle runs from the binary, never from a tree of ours.
    private func resolveServedBundleId(of release: Release?) -> String? {
        guard let release = release, !isCarryingEmbeddedBundle(release) else { return nil }
        return release.bundleId
    }

    private func persistServedBundle(of release: Release?) {
        loader.persistServedBundle(bundleId: resolveServedBundleId(of: release))
    }

    private func loadBundle() {
        guard loader.servedBundleId() != resolveServedBundleId(of: state.currentRelease) else { return }
        loadServedBundle(of: state.currentRelease)
        unsettleStart()
    }

    private func reloadApp() {
        loadServedBundle(of: state.currentRelease)
        gateReloadedApp()
    }

    private func loadServedBundle(of release: Release?) {
        loader.loadServedBundle(bundleId: resolveServedBundleId(of: release))
        bundleLoadCount.increment()
    }

    private func hasLoadedBundle(since bundleLoadCountAtSignal: Int) -> Bool {
        return bundleLoadCount.value != bundleLoadCountAtSignal
    }

    private func gateReloadedApp() {
        unsettleStart()
        announceRollback()
        if isCurrentReleaseUnconfirmed() {
            startReadyTimer()
        }
    }

    // A held restart is moot: the reloaded app runs what the state says.
    private func unsettleStart() {
        hasStartSettled = false
        queuedRestart = nil
    }

    // The served bundle is persisted first, so the next start switches if this run never does.
    private func restartIntoNextRelease() {
        if let next = state.nextRelease {
            persistServedBundle(of: next.release)
        }
        restartThroughGate(isAskedByApp: false) { [self] in applyNextRelease() }
    }

    // The release may have left the index or been dropped while the restart was held.
    // Then the host only reloads when it serves another bundle than the current one.
    private func applyNextRelease() {
        discardNextReleaseThatLeftTheIndex()
        guard state.nextRelease != nil else {
            if loader.servedBundleId() != resolveServedBundleId(of: state.currentRelease) {
                reloadApp()
            }
            return
        }
        switchToNextRelease()
        reloadApp()
    }

    // One restart is held at most: the app's replaces a held one, the core's yields to it.
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

    private func settleStart() {
        hasStartSettled = true
        if hasAnnouncedRollback {
            hasAnnouncedRollback = false
            state.pendingRollbackEvent = nil
        }
        runQueuedRestart()
    }

    // The notice stays stored until the app is up after it, so JavaScript that listens late still gets it.
    private func announceRollback() {
        guard let event = state.pendingRollbackEvent else { return }
        hasAnnouncedRollback = true
        listener.updateRolledBack(event)
    }

    // A release waiting to apply is dropped, since the cycle chose the adopted one over it.
    private func adoptInPlace(_ release: Release?) {
        let wasConfirmed = !isCurrentReleaseUnconfirmed()
        state.currentRelease = release
        state.nextRelease = nil
        if wasConfirmed {
            state.fallbackRelease = release
        }
        persistServedBundle(of: release)
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
            if configuration.checkStrategy == .auto {
                startAutomaticCycle(trigger: .start)
            }
        }
    }

    // The caller reloads. A rollback never waits for the app to be up.
    private func rollbackCurrentRelease(reason: RollbackReason, detail: String?) {
        guard let current = state.currentRelease else { return }
        stopReadyTimer()
        state.failedBundleIds = Array(Set(state.failedBundleIds + [current.bundleId])).sorted()
        let fallback = resolveFallbackRelease()
        state.currentRelease = fallback
        state.nextRelease = nil
        let rollback = UpdateRolledBackEvent(fromRelease: current, toRelease: fallback, reason: reason)
        state.lastRollback = rollback
        state.pendingRollbackEvent = rollback
        hasAnnouncedRollback = false
        enqueueDeviceEvent(.failed(releaseId: current.id, reason: reason.rawValue, detail: detail))
        record(LogEntry.ofRollback(rollback, at: clock.now))
        persistServedBundle(of: fallback)
    }

    private func resolveFallbackRelease() -> Release? {
        guard let fallback = state.fallbackRelease,
              !state.failedBundleIds.contains(fallback.bundleId),
              !(state.cachedIndex?.body.revokedReleaseIds.contains(fallback.id) ?? false),
              hasEveryFile(of: fallback) else {
            return nil
        }
        return fallback
    }

    private func hasEveryFile(of release: Release) -> Bool {
        guard !isCarryingEmbeddedBundle(release) else { return true }
        guard let manifest = files.readManifest(bundleId: release.bundleId) else { return false }
        return files.isComplete(manifest, embedded: embedded)
    }

    private func revertToEmbedded() {
        stopReadyTimer()
        state.currentRelease = nil
        state.nextRelease = nil
        persistServedBundle(of: nil)
        restartThroughGate(isAskedByApp: false) { [self] in reloadApp() }
    }

    // The readiness window runs in the foreground only, so a gate armed in the background waits for the resume.
    private func startReadyTimer() {
        stopReadyTimer()
        guard backgroundedAt == nil else {
            isReadyTimerPaused = true
            return
        }
        readyTimer = scheduler.schedule(after: configuration.readyTimeoutSeconds) { [weak self] in
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

    // The full window starts again: time already spent in the foreground counts for nothing.
    private func resumeReadyTimer() {
        guard isReadyTimerPaused else { return }
        startReadyTimer()
    }

    // Settling the start before the rollback lets a held restart run as the reload to the fallback.
    // A timeout that fires as the timer stops is ignored.
    func handleReadyTimeout() {
        guard readyTimer != nil, isCurrentReleaseUnconfirmed() else { return }
        hasStartSettled = true
        rollbackCurrentRelease(reason: .readinessTimedOut, detail: nil)
        restartThroughGate(isAskedByApp: false) { [self] in reloadApp() }
    }

    private func scheduleIntervalSync(after seconds: TimeInterval) {
        intervalTimer?.cancel()
        guard configuration.checkStrategy == .auto else { return }
        intervalTimer = scheduler.schedule(after: seconds) { [weak self] in
            await self?.startAutomaticCycle(trigger: .interval)
        }
    }

    // The served trees go first, since their links hold the bytes.
    private func deleteUnusedFiles() {
        let kept = Set([state.currentRelease, state.nextRelease?.release, state.fallbackRelease].compactMap { $0?.bundleId })
        for bundleId in files.bundleIds() where !kept.contains(bundleId) {
            loader.deleteProjection(bundleId: bundleId)
            files.deleteBundle(bundleId: bundleId)
        }
        files.deleteUnusedFiles(keepingBundleIds: kept)
    }

    enum IndexFetch {
        case index(ChannelIndex)
        case offline
        case invalid(String)
        case absent
        // The runtime channel serves no index, so the choice is cleared and the build's channel takes over.
        case gone
    }

    private func resolveChannelId() async -> ChannelResolution {
        if let id = getChannel().id { return .id(id) }
        guard case .name(let name) = state.channel else { return .missing }
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
            resolvedChannelName = (name, entry.id)
            return .id(entry.id)
        case 404:
            return .unknown
        default:
            return .offline
        }
    }

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
            if let cached = cached, isMovingBackwards(from: cached, to: index) {
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

    private func isMovingBackwards(from cached: CachedIndex, to index: ChannelIndex) -> Bool {
        return clock.now.timeIntervalSince(cached.fetchedAt) < Core.cachedIndexMaxAge && index.sequence < cached.body.sequence
    }

    private var isDisabledInThisBuild: Bool {
        return configuration.embeddedBundleManifest == nil || (device.isDebugBuild && !configuration.isEnabledInDebugBuilds)
    }

    private func deviceInfo() -> DeviceInfo {
        return DeviceInfo(attributes: state.attributes, binaryBuild: device.binaryBuild, binaryVersion: device.binaryVersion, builtAt: configuration.builtAt, currentRelease: state.currentRelease, deviceId: state.deviceId, failedBundleIds: state.failedBundleIds, fingerprint: configuration.fingerprint, osVersion: device.osVersion, reportedAt: state.reportedAt)
    }

    private func recordChecked(_ release: IndexRelease, in index: ChannelIndex, status: SyncStatus, reason: SkippedReason? = nil, conditionType: ConditionType? = nil) {
        var checked = state.checkedReleaseIds.filter { id in index.releases.contains { $0.id == id } }
        guard !checked.contains(release.id) else {
            state.checkedReleaseIds = checked
            return
        }
        checked.append(release.id)
        state.checkedReleaseIds = checked
        enqueueDeviceEvent(.checked(releaseId: release.id, status: status, reason: reason, conditionType: conditionType))
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

    private func sendDeviceEvents() async {
        guard !isSendingDeviceEvents, !isDisabledInThisBuild else { return }
        let events = state.unsentEvents
        var report = buildDeviceReport()
        if report?.isReadable == false {
            record(LogEntry(at: clock.now, code: "report_unreadable", message: "the device report stays unsent: a fact or an attribute is one the events endpoint refuses"))
            report = nil
        }
        guard !events.isEmpty || report != nil else { return }
        let request = DeviceEventsRequest(deviceId: state.deviceId, events: events, platform: device.platform, report: report, sdkVersion: device.sdkVersion)
        guard request.isReadable else {
            record(LogEntry(at: clock.now, code: "report_unreadable", message: "\(events.count) events kept: the SDK's version or the platform is one the events endpoint refuses"))
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
            state.reportedAt = DeviceEventsAcknowledgement(hasReport: report != nil, reportedAt: reportedAt).resolveKeptReportedAt(held: state.reportedAt)
            if let report = report {
                state.acknowledgedReport = report
            }
        case .refused:
            dropBatchEvents()
        case .failed:
            break
        }
    }

    // Only the events enqueued while the batch was in flight stay, also when the outbox cap dropped events of the batch meanwhile.
    private func dropBatchEvents() {
        state.unsentEvents = Array(state.unsentEvents.suffix(eventCountEnqueuedInFlight))
    }

    // A device without a channel reports nothing, since a row for it would mislead.
    private func buildDeviceReport() -> DeviceReport? {
        let channel = getChannel()
        guard let channelId = channel.id else { return nil }
        let report = DeviceReport(attributes: state.attributes, binaryBuild: device.binaryBuild, binaryVersion: device.binaryVersion, channelId: channelId, channelSource: channel.source, embeddedBundleId: configuration.embeddedBundleId, fingerprint: configuration.fingerprint, osVersion: device.osVersion, releaseId: state.currentRelease?.id)
        if report == state.acknowledgedReport, let reportedAt = state.reportedAt, Iso8601.resolveUtcMonth(of: reportedAt) == Iso8601.resolveUtcMonth(of: clock.now) {
            return nil
        }
        return report
    }
}

// A readiness signal reads the count before it waits for the actor, so it lives outside the actor.
final class BundleLoadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

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

    // Returns `nil` when no answer came within the timeout.
    func wait(timeout: TimeInterval) -> String?? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return bundleId
    }
}
