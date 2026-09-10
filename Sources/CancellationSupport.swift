import Foundation
import os

enum TranscriptionExecutionError: LocalizedError {
    case queuedTimedOut
    case timedOut
    case busy

    var errorDescription: String? {
        switch self {
        case .queuedTimedOut:
            return "Transcription timed out while waiting for the model. No model operation was started for this request. Try again shortly."
        case .timedOut:
            return "Transcription timed out. The current model operation is being stopped."
        case .busy:
            return "The transcription service is busy or still stopping a previous operation. Try again after it finishes."
        }
    }
}

/// Shared by Swift cancellation, the deadline timer, and whisper's C abort callback.
/// Cancelling a caller never frees memory that an in-flight C invocation still owns.
final class TranscriptionCancellation: @unchecked Sendable {
    private struct State {
        var failure: Error?
        var started = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let deadline: ContinuousClock.Instant

    init(timeoutSeconds: TimeInterval) {
        deadline = .now.advanced(by: .seconds(timeoutSeconds))
    }

    func stop(with error: Error) {
        state.withLock { state in
            guard state.failure == nil else { return }
            if case TranscriptionExecutionError.timedOut = error {
                state.failure = state.started
                    ? TranscriptionExecutionError.timedOut
                    : TranscriptionExecutionError.queuedTimedOut
            } else {
                state.failure = error
            }
        }
    }

    var error: Error? {
        state.withLock { state in
            if state.failure == nil, ContinuousClock.now >= deadline {
                state.failure = state.started
                    ? TranscriptionExecutionError.timedOut
                    : TranscriptionExecutionError.queuedTimedOut
            }
            return state.failure
        }
    }

    var isCancelled: Bool { error != nil }

    func checkCancellation() throws {
        if let error { throw error }
    }

    /// Linearizes entry into the serial operation with cancellation/deadlines.
    /// Merely occupying the queue's active slot is not evidence that C work began.
    /// A deadline that wins this lock leaves `started` false and cannot enter the body.
    func beginExecution() throws {
        let error = state.withLock { state -> Error? in
            if state.failure == nil, ContinuousClock.now >= deadline {
                state.failure = TranscriptionExecutionError.queuedTimedOut
            }
            guard state.failure == nil else { return state.failure }
            state.started = true
            return nil
        }
        if let error { throw error }
    }
}

private protocol TranscriptionJob: AnyObject, Sendable {
    var id: UUID { get }
    var cancellation: TranscriptionCancellation { get }
    func run()
    @discardableResult func stop(with error: Error) -> Bool
}

private final class TypedTranscriptionJob<Output>: TranscriptionJob, @unchecked Sendable {
    typealias Operation = @Sendable (TranscriptionCancellation) throws -> Output
    private struct State {
        var operation: Operation?
        var continuation: CheckedContinuation<Output, Error>?
        var result: Result<Output, Error>?
        var timer: DispatchSourceTimer?
    }

    let id = UUID()
    let cancellation: TranscriptionCancellation
    private let state: OSAllocatedUnfairLock<State>

    init(timeoutSeconds: TimeInterval, operation: @escaping Operation) {
        cancellation = TranscriptionCancellation(timeoutSeconds: timeoutSeconds)
        state = OSAllocatedUnfairLock(initialState: State(operation: operation))
    }

    func install(_ continuation: CheckedContinuation<Output, Error>) {
        let result = state.withLock { state -> Result<Output, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func armDeadline(after seconds: TimeInterval,
                     onTimeout: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: onTimeout)
        // Activate before publishing: a concurrent finish may cancel the timer.
        timer.activate()
        let finished = state.withLock { state -> Bool in
            guard state.result == nil else { return true }
            state.timer = timer
            return false
        }
        if finished { timer.cancel() }
    }

    func run() {
        // Only the serial worker takes the body. Pending cancellations release it.
        let operation = state.withLock { state -> Operation? in
            let operation = state.operation
            state.operation = nil
            return operation
        }
        guard let operation else { return }
        let result = Result {
            try cancellation.beginExecution()
            let value = try operation(cancellation)
            try cancellation.checkCancellation()
            return value
        }
        finish(result)
    }

    @discardableResult
    func stop(with error: Error) -> Bool {
        finish(.failure(error), cancelling: error)
    }

    @discardableResult
    private func finish(_ result: Result<Output, Error>, cancelling error: Error? = nil) -> Bool {
        let completion = state.withLock { state -> (CheckedContinuation<Output, Error>?, DispatchSourceTimer?, Result<Output, Error>)? in
            guard state.result == nil else { return nil }
            if let error { cancellation.stop(with: error) }
            let resolved = error.map { Result<Output, Error>.failure(cancellation.error ?? $0) } ?? result
            state.result = resolved
            state.operation = nil
            let completion = (state.continuation, state.timer, resolved)
            state.continuation = nil
            state.timer = nil
            return completion
        }
        guard let (continuation, timer, result) = completion else { return false }
        timer?.cancel()
        continuation?.resume(with: result)
        return true
    }
}

/// Dispatches only one work item at a time, retaining at most `maximumPending`
/// queued bodies. A timed-out/cancelled C call keeps the active slot until it
/// actually returns; callers never start another operation on its whisper ctx.
final class CancellableTranscriptionQueue: @unchecked Sendable {
    private struct State {
        var active: (any TranscriptionJob)?
        var pending: [any TranscriptionJob] = []
        var stopped = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue
    private let maximumPending: Int

    init(label: String, maximumPending: Int = 2) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maximumPending = max(0, maximumPending)
    }

    func checkAvailability() throws {
        let available = state.withLock {
            !$0.stopped && $0.active?.cancellation.isCancelled != true &&
                ($0.active == nil || $0.pending.count < maximumPending)
        }
        guard available else { throw TranscriptionExecutionError.busy }
    }

    func perform<Output>(timeoutSeconds: TimeInterval,
                         operation: @escaping @Sendable (TranscriptionCancellation) throws -> Output) async throws -> Output {
        try Task.checkCancellation()
        let timeout = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 60
        let job = TypedTranscriptionJob(timeoutSeconds: timeout, operation: operation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.install(continuation)
                job.armDeadline(after: timeout) { [weak self, weak job] in
                    guard let job else { return }
                    self?.stop(job, with: TranscriptionExecutionError.timedOut)
                }
                submit(job)
            }
        } onCancel: {
            self.stop(job, with: CancellationError())
        }
    }

    func assertOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Close admission and cancel callers without waiting on the serial worker.
    /// The service's process-exit path deliberately leaves its C context allocated:
    /// a stuck GPU kernel cannot be safely interrupted or force-freed here.
    func shutdown() {
        let jobs = state.withLock { state -> [any TranscriptionJob] in
            state.stopped = true
            let jobs = state.pending + (state.active.map { [$0] } ?? [])
            state.pending.removeAll()
            return jobs
        }
        for job in jobs { job.stop(with: CancellationError()) }
    }

    private func submit(_ job: any TranscriptionJob) {
        let decision = state.withLock { state -> Int in
            guard !job.cancellation.isCancelled else { return 0 }
            guard !state.stopped, state.active?.cancellation.isCancelled != true else { return -1 }
            if state.active == nil {
                state.active = job
                return 1
            }
            guard state.pending.count < maximumPending else { return -1 }
            state.pending.append(job)
            return 0
        }
        if decision == 1 { dispatch(job) }
        if decision == -1 { job.stop(with: TranscriptionExecutionError.busy) }
    }

    private func stop(_ job: any TranscriptionJob, with error: Error) {
        guard job.stop(with: error) else { return }
        let rejected = state.withLock { state -> [any TranscriptionJob] in
            if state.active?.id == job.id {
                // No backlog should wait behind a C call that may not cooperate.
                let pending = state.pending
                state.pending.removeAll()
                return pending
            }
            state.pending.removeAll { $0.id == job.id }
            return []
        }
        for pending in rejected { pending.stop(with: TranscriptionExecutionError.busy) }
    }

    private func dispatch(_ job: any TranscriptionJob) {
        queue.async { [self] in
            job.run()
            let next = state.withLock { state -> (any TranscriptionJob)? in
                state.active = nil
                guard !state.stopped, !state.pending.isEmpty else { return nil }
                let next = state.pending.removeFirst()
                state.active = next
                return next
            }
            if let next { dispatch(next) }
        }
    }
}
