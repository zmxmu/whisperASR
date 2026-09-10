// Independent, model-free checks for the same executor used by whisper_full.
// swiftc -parse-as-library Sources/CancellationSupport.swift Tests/TranscriptionCancellationChecks.swift -o /tmp/TranscriptionCancellationChecks && /tmp/TranscriptionCancellationChecks
import Foundation
import os

private final class Probe: @unchecked Sendable {
    let values = OSAllocatedUnfairLock(initialState: [String: Int]())
    func mark(_ name: String) { values.withLock { $0[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { values.withLock { $0[name, default: 0] } }
}

private final class LifetimeProbe: @unchecked Sendable {
    let probe: Probe
    init(_ probe: Probe) { self.probe = probe }
    deinit { probe.mark("context-released") }
    func finished() { probe.mark("hard-deadline-returned") }
}

private final class PendingCapture: @unchecked Sendable {
    let probe: Probe
    let releaseMarker: String
    init(probe: Probe, releaseMarker: String) {
        self.probe = probe
        self.releaseMarker = releaseMarker
    }
    deinit { probe.mark(releaseMarker) }
    func ran(_ marker: String) { probe.mark(marker) }
}

@main
struct TranscriptionCancellationChecks {
    static func eventually(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            precondition(ContinuousClock.now < end, "Timed out waiting for the test condition")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func expectFailure<T>(_ task: Task<T, Error>,
                                 matching predicate: (Error) -> Bool) async {
        do {
            _ = try await task.value
            preconditionFailure("Expected failure")
        } catch {
            precondition(predicate(error), "Unexpected error: \(error)")
        }
    }

    static func isTimeout(_ error: Error) -> Bool {
        guard case TranscriptionExecutionError.timedOut = error else { return false }
        return true
    }

    static func isQueuedTimeout(_ error: Error) -> Bool {
        guard case TranscriptionExecutionError.queuedTimedOut = error else { return false }
        return true
    }

    static func isBusy(_ error: Error) -> Bool {
        guard case TranscriptionExecutionError.busy = error else { return false }
        return true
    }

    static func main() async throws {
        let queue = CancellableTranscriptionQueue(label: "checks.serial", maximumPending: 1)
        let probe = Probe()
        let unblock = DispatchSemaphore(value: 0)

        // Simulate a C/GPU call that does not cooperate until explicitly unblocked.
        let active = Task {
            try await queue.perform(timeoutSeconds: 5) { _ in
                probe.mark("active")
                precondition(unblock.wait(timeout: .now() + 3) == .success)
                probe.mark("returned")
                return 1
            }
        }
        try await eventually { probe.count("active") == 1 }

        var pendingCapture: PendingCapture? = PendingCapture(
            probe: probe, releaseMarker: "pending-cancel-capture-released")
        let pending = Task { [held = pendingCapture!] in
            try await queue.perform(timeoutSeconds: 5) { [held] _ in
                held.ran("pending-ran")
                return 2
            }
        }
        pendingCapture = nil
        try await eventually { (try? queue.checkAvailability()) == nil }

        // The queue retains at most one pending body, rejecting extra submissions.
        let overflow = Task {
            try await queue.perform(timeoutSeconds: 5) { _ in 3 }
        }
        await expectFailure(overflow, matching: isBusy)
        let beforeCancel = ContinuousClock.now
        pending.cancel()
        await expectFailure(pending) { $0 is CancellationError }
        precondition(beforeCancel.duration(to: .now) < .milliseconds(300))
        precondition(probe.count("pending-ran") == 0)
        try await eventually { probe.count("pending-cancel-capture-released") == 1 }

        // A queued timeout returns promptly without requiring active C to return.
        var timeoutCapture: PendingCapture? = PendingCapture(
            probe: probe, releaseMarker: "pending-timeout-capture-released")
        let waitingTimeout = Task { [held = timeoutCapture!] in
            try await queue.perform(timeoutSeconds: 0.04) { [held] _ in
                held.ran("expired-ran")
                return 4
            }
        }
        timeoutCapture = nil
        await expectFailure(waitingTimeout, matching: isQueuedTimeout)
        precondition(probe.count("returned") == 0)
        precondition(probe.count("expired-ran") == 0)
        try await eventually { probe.count("pending-timeout-capture-released") == 1 }

        // Cancelling the active caller must neither wait for nor release C's slot.
        let beforeActiveCancel = ContinuousClock.now
        active.cancel()
        await expectFailure(active) { $0 is CancellationError }
        precondition(beforeActiveCancel.duration(to: .now) < .milliseconds(300))
        let blocked = Task {
            try await queue.perform(timeoutSeconds: 5) { _ in
                probe.mark("unsafe-overlap")
                return 5
            }
        }
        await expectFailure(blocked, matching: isBusy)
        precondition(probe.count("unsafe-overlap") == 0)
        unblock.signal()
        try await eventually { probe.count("returned") == 1 }
        try await eventually { (try? queue.checkAvailability()) != nil }
        let successful = try await queue.perform(timeoutSeconds: 1) { _ in 42 }
        precondition(successful == 42, "Late completion must not corrupt subsequent requests")

        // Deadline stops an executing cooperative body via the callback signal.
        let cooperative = Task {
            try await queue.perform(timeoutSeconds: 0.04) { cancellation in
                while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                probe.mark("cooperative-stopped")
                try cancellation.checkCancellation()
                return 6
            }
        }
        await expectFailure(cooperative, matching: isTimeout)
        try await eventually { probe.count("cooperative-stopped") == 1 }
        try await eventually { (try? queue.checkAvailability()) != nil }

        // An already-expired deadline never enters the operation.
        let expired = Task {
            try await queue.perform(timeoutSeconds: 0) { _ in
                probe.mark("zero-deadline-ran")
                return 7
            }
        }
        await expectFailure(expired, matching: isQueuedTimeout)
        precondition(probe.count("zero-deadline-ran") == 0)

        // A deadline also returns for a non-cooperative body. Its captured C-like
        // owner must remain alive, while new calls fail quickly rather than queue.
        let hardQueue = CancellableTranscriptionQueue(label: "checks.hard-deadline")
        let hardUnblock = DispatchSemaphore(value: 0)
        var owner: LifetimeProbe? = LifetimeProbe(probe)
        let hardDeadline = Task { [held = owner!] in
            try await hardQueue.perform(timeoutSeconds: 0.04) { [held] _ in
                probe.mark("hard-deadline-started")
                precondition(hardUnblock.wait(timeout: .now() + 3) == .success)
                held.finished()
                return 10
            }
        }
        owner = nil
        try await eventually { probe.count("hard-deadline-started") == 1 }
        await expectFailure(hardDeadline, matching: isTimeout)
        precondition(probe.count("context-released") == 0, "Timed-out C operation lost its context owner")
        let duringHardTimeout = Task {
            try await hardQueue.perform(timeoutSeconds: 1) { _ in 11 }
        }
        await expectFailure(duringHardTimeout, matching: isBusy)
        let beforeShutdown = ContinuousClock.now
        hardQueue.shutdown()
        precondition(beforeShutdown.duration(to: .now) < .milliseconds(300))
        precondition(probe.count("context-released") == 0, "Shutdown released an in-flight context")
        hardUnblock.signal()
        try await eventually { probe.count("hard-deadline-returned") == 1 }
        try await eventually { probe.count("context-released") == 1 }

        // Exercise timer/cancellation/normal-completion races. A second resume
        // would trap in CheckedContinuation; both valid winning outcomes are OK.
        for index in 0..<100 {
            let races = CancellableTranscriptionQueue(label: "checks.race.\(index)")
            let startedMarker = "race-started-\(index)"
            let task = Task {
                try await races.perform(timeoutSeconds: 0.002) { cancellation in
                    probe.mark(startedMarker)
                    Thread.sleep(forTimeInterval: index.isMultiple(of: 2) ? 0.001 : 0.003)
                    try cancellation.checkCancellation()
                    return 8
                }
            }
            if index.isMultiple(of: 3) { task.cancel() }
            do {
                let value = try await task.value
                precondition(value == 8)
            } catch {
                precondition(error is CancellationError || isTimeout(error) || isQueuedTimeout(error))
                if isQueuedTimeout(error) {
                    precondition(probe.count(startedMarker) == 0,
                                 "A queue deadline must never enter its operation body")
                }
                if isTimeout(error) {
                    // The deadline can resume the client just after atomic entry but
                    // before the body gets CPU time; wait for the committed entry.
                    try await eventually { probe.count(startedMarker) == 1 }
                }
            }
        }

        queue.shutdown()
        let afterShutdown = Task {
            try await queue.perform(timeoutSeconds: 1) { _ in 9 }
        }
        await expectFailure(afterShutdown, matching: isBusy)
        print("PASS: queued vs executing deadlines, zero deadline never starts, queued capture release, bounded backlog, active cancellation without ctx overlap, late return, cooperative abort, non-cooperative context lifetime, nonblocking shutdown, 100 start/completion races")
    }
}
