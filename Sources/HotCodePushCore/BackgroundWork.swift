import Foundation

// The work the core starts and no caller awaits, kept so that tests can wait for it.
// A lock and not an actor, so the downloader starts work without a hop to the core.
final class BackgroundWork {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // For a caller off the core's actor. Its work runs on no actor of its own.
    func start(_ work: @escaping () async -> Void) {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = Task {
            await work()
            self.finish(id: id)
        }
    }

    // The core makes its tasks itself, so they keep the core's isolation and run in its order.
    func add(_ task: Task<Void, Never>, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = task
    }

    func finish(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = nil
    }

    // It also waits for work started meanwhile.
    func waitForAll() async {
        while let task = resolveAnyTask() {
            await task.value
        }
    }

    private func resolveAnyTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values.first
    }
}
