// Standalone deterministic PCM/boundary regressions; no model, microphone, or network.
// swiftc -O Sources/Models.swift Sources/LiveAudioBuffer.swift Sources/LiveTranscriptionAssembler.swift Tests/LiveAudioChecks.swift -o .build/live-audio-checks
// .build/live-audio-checks
import Foundation

@main
struct LiveAudioChecks {
    static let rate = 16_000
    static func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text)
    }

    static func main() {
        // Reproduce eviction BETWEEN the caller's previous observation and its
        // next snapshot. Speech still present must not turn into silent PCM.
        let buffer = LiveAudioBuffer(maximumSamples: 90, retainedSamples: 60)
        buffer.append((0..<90).map { Float($0 + 1) })
        let before = buffer.snapshot(from: 0, maximumCount: 90)
        buffer.append([91])
        let evicted = buffer.snapshot(from: 0, maximumCount: 10)
        precondition(evicted.wasEvicted && evicted.oldest == 31)
        precondition(evicted.start == 31 && evicted.end == 41 && evicted.availableEnd == 91)
        precondition(evicted.samples == (32...41).map(Float.init) && evicted.rms > 0)
        precondition(before.samples.count == 90 && before.samples[0] == 1)
        buffer.trim(upTo: 50)
        precondition(buffer.snapshot(from: 50, maximumCount: 4).samples == [51, 52, 53, 54])
        buffer.clear()
        precondition(buffer.availableRange == 0..<0 && before.samples.count == 90)

        // The selected pause is its START, not the final 300ms of a longer pause.
        let frame = 16
        let levels: [Float] = [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1]
        let scan = LiveAudioBuffer(maximumSamples: 1000, retainedSamples: 800)
        scan.append(levels.flatMap { Array(repeating: $0, count: frame) })
        let snapshot = scan.snapshot(from: 0, maximumCount: 1000)
        precondition(snapshot.lastSilenceCut(frameSamples: frame) == 13 * frame)
        precondition(abs(snapshot.rms - sqrt(Float(8) / 20)) < 0.00001)
        scan.clear()
        scan.append(Array(repeating: 0, count: frame * 10))
        precondition(scan.snapshot(from: 0, maximumCount: 1000).lastSilenceCut(frameSamples: frame) == nil)

        // Concurrent cap/trim reads must be coherent: every value encodes its
        // absolute index, so mismatched metadata and samples are detected.
        let concurrent = LiveAudioBuffer(maximumSamples: 90, retainedSamples: 60)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for index in 0..<5000 { concurrent.append([Float(index)]) }
            group.leave()
        }
        for _ in 0..<2000 {
            let window = concurrent.snapshot(from: 0, maximumCount: 30)
            precondition(window.end - window.start == window.samples.count)
            precondition(window.availableEnd >= window.end && window.start >= window.oldest)
            for (offset, value) in window.samples.enumerated() {
                precondition(value == Float(window.start + offset))
            }
        }
        group.wait()

        // A paragraph crossing an early pause remains mutable, even if its start
        // is before the pause. Once forced, that same old pause cannot stall it.
        var assembler = LiveTranscriptionAssembler()
        var update = assembler.apply(result: [segment(0, 20, "连续说话 English")],
            audioStart: 0, audioEnd: 20 * rate, silenceCut: 3 * rate, force: false, final: false)
        precondition(update.sealedCount == 0 && assembler.displayedTail.count == 1)
        update = assembler.apply(result: [segment(0, 20, "连续说话 English")],
            audioStart: 0, audioEnd: 20 * rate, silenceCut: 3 * rate, force: true, final: false)
        precondition(update.sealedCount == 1 && assembler.sealedSampleCount == 20 * rate)
        precondition(assembler.tailStart == 19 * rate)
        let history = assembler.sealedSegments

        // Entire overlap segments vanish; a crossing segment may only dedup a
        // whole matching word. Already committed history remains byte-for-byte.
        update = assembler.apply(result: [segment(19, 20, "English"), segment(19.5, 21, "English continues")],
            audioStart: 19 * rate, audioEnd: 21 * rate, silenceCut: nil, force: false, final: false)
        precondition(update.replacingFrom == 1 && update.segments.count == 1)
        precondition(update.segments[0].text == "continues")
        precondition(assembler.sealedSegments == history && assembler.displayedTail[0].start == 20)

        // Force normally commits whole paragraphs and keeps the last paragraph
        // mutable. A later rewrite can replace it without rolling back history.
        var split = LiveTranscriptionAssembler()
        update = split.apply(result: [segment(0, 5, "第一句"), segment(5, 10, "第二句"), segment(10, 20, "未完成")],
            audioStart: 0, audioEnd: 20 * rate, silenceCut: nil, force: true, final: false)
        precondition(update.sealedCount == 2 && split.sealedSampleCount == 10 * rate)
        let prefix = split.sealedSegments
        update = split.apply(result: [segment(9, 10, "第二句"), segment(10, 21, "完整的第三句")],
            audioStart: 9 * rate, audioEnd: 21 * rate, silenceCut: nil, force: false, final: true)
        precondition(update.replacingFrom == 2 && split.sealedSegments.prefix(2).elementsEqual(prefix))
        precondition(split.sealedSegments.last?.text == "完整的第三句" && split.displayedTail.isEmpty)

        // No-speech decoding must make progress on a forced window, and a final
        // utterance shorter than the live minimum must still be committed.
        var empty = LiveTranscriptionAssembler()
        _ = empty.apply(result: [], audioStart: 0, audioEnd: 20 * rate,
                        silenceCut: nil, force: true, final: false)
        precondition(empty.sealedSampleCount == 20 * rate)
        _ = empty.apply(result: [segment(20, 20.2, "好")], audioStart: 19 * rate,
                        audioEnd: 20 * rate + 3200, silenceCut: nil, force: false, final: true)
        precondition(empty.sealedSegments.last?.text == "好" && empty.sealedSampleCount == 323_200)
        let prior = empty.sealedSegments
        _ = empty.skip(to: 40 * rate)
        precondition(empty.sealedSegments == prior && empty.tailStart == 40 * rate)

        // Real repetitions and subword matches must survive deduplication.
        precondition(LiveTranscriptionAssembler.trimBoundaryOverlap(previous: "是", current: "是这样") == "是这样")
        precondition(LiveTranscriptionAssembler.trimBoundaryOverlap(previous: "the", current: "hello") == "hello")
        precondition(LiveTranscriptionAssembler.trimBoundaryOverlap(previous: "ship", current: "shipping") == "shipping")
        precondition(LiveTranscriptionAssembler.trimBoundaryOverlap(previous: "use Swift", current: "Swift again") == "again")
        precondition(LiveTranscriptionAssembler.trimBoundaryOverlap(previous: "开始测试", current: "测试继续") == "继续")
        checkIntegerBoundaries()
        checkEmptyDraftRetention()
        print("Live audio checks passed: atomic eviction, bounded snapshots, concurrent cap, integer pause/force/overlap boundaries, immutable history, empty draft retention, forced/final drain.")
    }

    static func checkIntegerBoundaries() {
        // Reproduce the real caller arithmetic, not just an isolated comparison:
        // 0.01 + 16.01 can be 16.020000000000003, while its sample cursor is 16.02.
        // Previously force moved that cursor without committing the paragraph;
        // the following overlap then dropped the still-uncommitted paragraph.
        let offsets = [160, 192_137, 3 * 3600 * rate + 137, 24 * 3600 * rate + 7]
        for offset in offsets {
            let offsetTime = Double(offset) / Double(rate)
            for tick in [1201, 1601, 1603, 1607, 1987, 1999] {
                let end = offsetTime + Double(tick) / 100
                let expectedSeal = offset + tick * 160
                var assembler = LiveTranscriptionAssembler()
                _ = assembler.skip(to: offset)
                let first = assembler.apply(result: [segment(offsetTime, end, "must survive")],
                    audioStart: offset, audioEnd: offset + 20 * rate,
                    silenceCut: nil, force: true, final: false)
                precondition(first.sealedSampleCount == expectedSeal && first.sealedCount == 1)
                precondition(assembler.sealedSegments.map(\.text) == ["must survive"])
                precondition(assembler.displayedTail.isEmpty)
                let nextStart = assembler.tailStart
                let overlapEnd = Double(nextStart) / Double(rate) + 1
                _ = assembler.apply(result: [segment(Double(nextStart) / Double(rate), overlapEnd, "must survive")],
                    audioStart: nextStart, audioEnd: offset + 21 * rate,
                    silenceCut: nil, force: false, final: false)
                precondition(assembler.sealedSegments.map(\.text) == ["must survive"])
                precondition(assembler.displayedTail.isEmpty)
            }

            // The same loss happened without force: a second paragraph crossing
            // the silence cut made the cursor fall back to the first paragraph's end.
            var paused = LiveTranscriptionAssembler()
            _ = paused.skip(to: offset)
            let expectedSeal = offset + 1601 * 160
            let next = segment(offsetTime + 17, offsetTime + 20, "second paragraph")
            let first = paused.apply(result: [segment(offsetTime, offsetTime + 16.01, "first paragraph"), next],
                audioStart: offset, audioEnd: offset + 20 * rate,
                silenceCut: offset + 18 * rate, force: false, final: false)
            precondition(first.sealedSampleCount == expectedSeal && first.sealedCount == 1)
            let nextStart = paused.tailStart
            _ = paused.apply(result: [segment(Double(nextStart) / Double(rate),
                Double(nextStart) / Double(rate) + 1, "first paragraph"), next],
                audioStart: nextStart, audioEnd: offset + 21 * rate,
                silenceCut: nil, force: false, final: false)
            precondition(paused.sealedSegments.map(\.text) == ["first paragraph"])
            precondition(paused.displayedTail.map(\.text) == ["second paragraph"])

            let cut = offset + 50_000
            for delta in [-1, 0, 1] {
                // A paragraph ending one sample AFTER the cut stays mutable.
                var ending = LiveTranscriptionAssembler()
                _ = ending.skip(to: offset)
                let ended = ending.apply(result: [segment(offsetTime, Double(cut + delta) / Double(rate), "at cut")],
                    audioStart: offset, audioEnd: cut + 2 * rate,
                    silenceCut: cut, force: false, final: false)
                precondition(ended.sealedCount == (delta <= 0 ? 1 : 0))
                precondition(ended.sealedSampleCount == (delta <= 0 ? cut : offset))

                // A new paragraph beginning one sample BEFORE the pause crosses
                // it; at/after the pause the cursor may advance through silence.
                var beginning = LiveTranscriptionAssembler()
                _ = beginning.skip(to: offset)
                let began = beginning.apply(result: [
                    segment(offsetTime, Double(cut - 100) / Double(rate), "complete"),
                    segment(Double(cut + delta) / Double(rate), Double(cut + 1000) / Double(rate), "crossing")
                ], audioStart: offset, audioEnd: cut + 2 * rate,
                   silenceCut: cut, force: false, final: false)
                precondition(began.sealedCount == 1)
                precondition(began.sealedSampleCount == (delta < 0 ? cut - 100 : cut))

                // Only an end strictly beyond the sealed sample is new content.
                var overlap = LiveTranscriptionAssembler()
                _ = overlap.skip(to: cut)
                let crossed = overlap.apply(result: [segment(Double(cut - 1000) / Double(rate),
                    Double(cut + delta) / Double(rate), "new content")],
                    audioStart: cut - 1000, audioEnd: cut + 2 * rate,
                    silenceCut: nil, force: false, final: false)
                precondition(crossed.segments.count == (delta > 0 ? 1 : 0))
            }
        }
    }

    static func checkEmptyDraftRetention() {
        var assembler = LiveTranscriptionAssembler()
        _ = assembler.apply(result: [segment(0, 12, "sealed history")],
            audioStart: 0, audioEnd: 12 * rate, silenceCut: nil, force: true, final: false)
        _ = assembler.apply(result: [segment(12, 13, "unsealed draft")],
            audioStart: 11 * rate, audioEnd: 13 * rate, silenceCut: nil, force: false, final: false)
        let history = assembler.sealedSegments
        let draft = assembler.displayedTail
        // Empty, whitespace-only, and entirely old-overlap results are equivalent
        // after filtering. Even force must not erase the previous draft or advance.
        let emptyResults: [[TranscriptionSegment]] = [[], [segment(12, 30, "  ")], [segment(11, 12, "sealed history")]]
        for result in emptyResults {
            let update = assembler.apply(result: result, audioStart: 11 * rate,
                audioEnd: 32 * rate, silenceCut: 25 * rate, force: true, final: false)
            precondition(update.keptDraftAfterEmpty)
            precondition(update.replacingFrom == 1 && update.sealedCount == 1)
            precondition(update.sealedSampleCount == 12 * rate)
            precondition(update.segments == draft && assembler.displayedTail == draft)
            precondition(assembler.sealedSegments == history)
        }
        // New recognition can still replace/finish the draft normally.
        let recovered = assembler.apply(result: [segment(12, 33, "recovered complete text")],
            audioStart: 11 * rate, audioEnd: 33 * rate, silenceCut: nil, force: false, final: true)
        precondition(!recovered.keptDraftAfterEmpty && recovered.sealedCount == 2)
        precondition(assembler.sealedSegments.first == history.first)
        precondition(assembler.sealedSegments.last?.text == "recovered complete text")
        precondition(assembler.displayedTail.isEmpty)
    }
}
