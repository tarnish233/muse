import Foundation

/// A bounded, deduplicating scheduler shared by asynchronous rendering resources.
///
/// The queue owns only task mechanics: FIFO ordering, concurrency limits, cancellation,
/// and stale-completion rejection. Resource-specific cache and refresh policy stays in
/// `RenderCoordinator`, so images and formulas cannot grow separate task registries again.
@MainActor
final class AsyncResourcePreparationQueue<Request, Output>
where Request: Hashable & Sendable, Output: Sendable {
    typealias Operation = @Sendable (Request) async -> Output
    typealias Completion = @MainActor @Sendable (Request, Output, Bool) -> Void

    private struct Pending {
        let request: Request
        let priority: TaskPriority
        let operation: Operation
        let completion: Completion
    }

    private struct Active {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let maximumConcurrentPreparations: Int
    private var active: [Request: Active] = [:]
    private var pending: [Pending] = []
    private var pendingHead = 0
    private var pendingRequests = Set<Request>()

    init(maximumConcurrentPreparations: Int) {
        precondition(maximumConcurrentPreparations > 0)
        self.maximumConcurrentPreparations = maximumConcurrentPreparations
    }

    deinit {
        for entry in active.values {
            entry.task.cancel()
        }
    }

    var activeCount: Int { active.count }
    var pendingCount: Int { pendingRequests.count }
    var isIdle: Bool { active.isEmpty && pendingRequests.isEmpty }

    func contains(_ request: Request) -> Bool {
        active[request] != nil || pendingRequests.contains(request)
    }

    @discardableResult
    func enqueue(
        _ request: Request,
        priority: TaskPriority = .utility,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) -> Bool {
        guard active[request] == nil, pendingRequests.insert(request).inserted else {
            return false
        }
        pending.append(Pending(
            request: request,
            priority: priority,
            operation: operation,
            completion: completion
        ))
        drain()
        return true
    }

    func cancel(_ request: Request) {
        pendingRequests.remove(request)
        active[request]?.task.cancel()
    }

    func cancelAll() {
        pendingRequests.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        for entry in active.values {
            entry.task.cancel()
        }
    }

    func waitUntilIdle() async {
        while !isIdle {
            let tasks = active.values.map(\.task)
            if tasks.isEmpty {
                await Task.yield()
            } else {
                for task in tasks {
                    await task.value
                }
            }
        }
    }

    private func drain() {
        while active.count < maximumConcurrentPreparations,
              let next = dequeue()
        {
            start(next)
        }
    }

    private func dequeue() -> Pending? {
        while pendingHead < pending.count {
            let next = pending[pendingHead]
            pendingHead += 1
            guard pendingRequests.remove(next.request) != nil else { continue }
            compactIfNeeded()
            return next
        }
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        return nil
    }

    private func compactIfNeeded() {
        guard pendingHead >= 256, pendingHead * 2 >= pending.count else { return }
        pending.removeFirst(pendingHead)
        pendingHead = 0
    }

    private func start(_ pending: Pending) {
        precondition(active.count < maximumConcurrentPreparations)
        let id = UUID()
        let request = pending.request
        let task = Task(priority: pending.priority) { [weak self] in
            let output = await pending.operation(request)
            let wasCancelled = Task.isCancelled
            self?.finish(
                request,
                id: id,
                output: output,
                wasCancelled: wasCancelled,
                completion: pending.completion
            )
        }
        active[request] = Active(id: id, task: task)
    }

    private func finish(
        _ request: Request,
        id: UUID,
        output: Output,
        wasCancelled: Bool,
        completion: Completion
    ) {
        guard active[request]?.id == id else { return }
        active.removeValue(forKey: request)
        completion(request, output, wasCancelled)
        drain()
    }
}
