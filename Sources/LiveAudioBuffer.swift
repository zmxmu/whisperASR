import Foundation
import Accelerate
import os

/// A coherent, bounded PCM window. Sample positions are absolute within one recording.
/// An evicted start is explicit: missing audio is never represented as zero energy.
struct LiveAudioSnapshot: Sendable {
    let requestedStart: Int
    let oldest: Int
    let start: Int
    let end: Int
    let availableEnd: Int
    let samples: [Float]

    var wasEvicted: Bool { requestedStart < oldest }
    var rms: Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { buffer in
            var value: Float = 0
            vDSP_rmsqv(buffer.baseAddress!, 1, &value, vDSP_Length(buffer.count))
            return value
        }
    }

    /// Returns the beginning of the rightmost complete silence run after speech.
    /// All scanning happens on this immutable copy, outside the capture lock.
    func lastSilenceCut(searchFrom: Int? = nil, frameSamples: Int = 1600,
                        silenceThreshold: Float = 0.001,
                        minSilenceFrames: Int = 3) -> Int? {
        guard frameSamples > 0, minSilenceFrames > 0 else { return nil }
        let offset = min(samples.count, max(0, (searchFrom ?? start) - start))
        let frameCount = (samples.count - offset) / frameSamples
        guard frameCount > 0 else { return nil }
        var speechSeen = false
        var runStart: Int?
        var latestCut: Int?
        samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress! + offset
            for frame in 0..<frameCount {
                var energy: Float = 0
                vDSP_rmsqv(base + frame * frameSamples, 1, &energy, vDSP_Length(frameSamples))
                if energy < silenceThreshold {
                    if runStart == nil { runStart = frame }
                    if speechSeen, let runStart, frame - runStart + 1 >= minSilenceFrames {
                        latestCut = start + offset + runStart * frameSamples
                    }
                } else {
                    speechSeen = true
                    runStart = nil
                }
            }
        }
        return latestCut
    }
}

/// The only owner of the mutable capture PCM. Keeping indices and samples under
/// one lock makes a snapshot valid even when the 90-to-60-second cap fires.
final class LiveAudioBuffer: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var oldest = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumSamples: Int
    private let retainedSamples: Int

    init(maximumSamples: Int = 16_000 * 90, retainedSamples: Int = 16_000 * 60) {
        precondition(maximumSamples > 0 && retainedSamples > 0 && retainedSamples <= maximumSamples)
        self.maximumSamples = maximumSamples
        self.retainedSamples = retainedSamples
    }

    var availableRange: Range<Int> {
        state.withLock { $0.oldest..<($0.oldest + $0.samples.count) }
    }

    func append(_ samples: [Float]) {
        state.withLock { state in
            state.samples.append(contentsOf: samples)
            if state.samples.count > maximumSamples {
                let drop = state.samples.count - retainedSamples
                state.samples.removeFirst(drop)
                state.oldest += drop
            }
        }
    }

    /// Takes the oldest requested window, not the newest window: callers can
    /// drain a stopped recording sequentially without silently skipping audio.
    func snapshot(from requestedStart: Int, maximumCount: Int) -> LiveAudioSnapshot {
        state.withLock { state in
            let availableEnd = state.oldest + state.samples.count
            let start = min(availableEnd, max(state.oldest, requestedStart))
            let count = min(max(0, maximumCount), availableEnd - start)
            let offset = start - state.oldest
            return LiveAudioSnapshot(
                requestedStart: requestedStart, oldest: state.oldest,
                start: start, end: start + count, availableEnd: availableEnd,
                samples: Array(state.samples[offset..<(offset + count)])
            )
        }
    }

    func trim(upTo absoluteIndex: Int) {
        state.withLock { state in
            let count = min(state.samples.count, max(0, absoluteIndex - state.oldest))
            guard count > 0 else { return }
            state.samples.removeFirst(count)
            state.oldest += count
        }
    }

    func clear() {
        state.withLock { state in
            state.samples.removeAll(keepingCapacity: true)
            state.oldest = 0
        }
    }
}
