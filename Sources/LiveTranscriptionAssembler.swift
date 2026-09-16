import Foundation

/// Reconciles one mutable ASR window with immutable, already published history.
/// Timestamps supplied to `apply` are absolute recording times, in seconds.
struct LiveTranscriptionAssembler {
    struct Publication {
        /// Replace the old display suffix starting here; never replace sealed history.
        let replacingFrom: Int
        /// Newly sealed paragraphs followed by the current mutable paragraphs.
        let segments: [TranscriptionSegment]
        let sealedCount: Int
        let sealedSampleCount: Int
        /// The decoder supplied no new text, so the previous unsealed draft was
        /// retained. Callers should await new captured audio before retrying.
        let keptDraftAfterEmpty: Bool
    }

    static let sampleRate = 16_000
    static let overlapSamples = 16_000
    static let forceSamples = 16_000 * 12
    private(set) var sealedSegments: [TranscriptionSegment] = []
    private(set) var sealedSampleCount = 0
    private(set) var displayedTail: [TranscriptionSegment] = []
    private var boundaryIsClean = true

    var tailStart: Int {
        max(0, sealedSampleCount - (boundaryIsClean ? 0 : Self.overlapSamples))
    }

    @discardableResult
    mutating func skip(to sample: Int) -> Publication {
        sealedSampleCount = max(sealedSampleCount, sample)
        displayedTail = []
        boundaryIsClean = true
        return Publication(replacingFrom: sealedSegments.count, segments: [],
                           sealedCount: sealedSegments.count, sealedSampleCount: sealedSampleCount,
                           keptDraftAfterEmpty: false)
    }

    mutating func apply(result: [TranscriptionSegment], audioStart: Int, audioEnd: Int,
                        silenceCut: Int?, force: Bool, final: Bool) -> Publication {
        let oldCount = sealedSegments.count
        let oldSeal = sealedSampleCount
        let audioEndTime = Double(audioEnd) / Double(Self.sampleRate)
        var tail: [TranscriptionSegment] = []
        for segment in result.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end?.isFinite != false else { continue }
            let end = min(segment.end ?? audioEndTime, audioEndTime)
            guard end >= 0, end >= segment.start else { continue }
            let endSample = min(audioEnd, Self.sample(at: end))
            let startSample = Self.sample(at: max(0, segment.start))
            // A segment wholly inside the one-second look-behind is not new speech.
            guard endSample > oldSeal, endSample >= startSample else { continue }
            var text = segment.text
            if tail.isEmpty, audioStart < oldSeal, startSample < oldSeal,
               let previous = sealedSegments.last?.text {
                text = Self.trimBoundaryOverlap(previous: previous, current: text)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // The caller adds two Double timestamps (window offset + centiseconds).
            // Canonical sample positions prevent one-ULP disagreement with the cursor.
            tail.append(TranscriptionSegment(
                start: Double(max(oldSeal, startSample)) / Double(Self.sampleRate),
                end: Double(endSample) / Double(Self.sampleRate), text: text))
        }

        if tail.isEmpty, !displayedTail.isEmpty, !final {
            return Publication(replacingFrom: oldCount, segments: displayedTail,
                               sealedCount: oldCount, sealedSampleCount: oldSeal,
                               keptDraftAfterEmpty: true)
        }

        var newSeal = oldSeal
        var clean = boundaryIsClean
        if let cut = silenceCut, cut > oldSeal, cut <= audioEnd {
            let complete = tail.prefix { Self.ends($0, by: cut) }
            // A decoder paragraph can cross a PCM pause. Never seal that paragraph
            // by its start timestamp, nor advance the audio cursor into its middle.
            if let crossing = tail.dropFirst(complete.count).first,
               Self.sample(at: crossing.start) < cut {
                if let end = complete.last?.end {
                    newSeal = max(oldSeal, Self.sample(at: end))
                    clean = false
                }
            } else {
                newSeal = cut
                clean = true
            }
        }

        if final {
            newSeal = max(oldSeal, audioEnd)
            clean = true
        } else if force, newSeal == oldSeal || audioEnd - newSeal >= Self.forceSamples {
            if tail.isEmpty {
                // Failed/no-speech decoding must not retry the same long window forever.
                newSeal = max(oldSeal, audioEnd)
            } else {
                // Usually retain the final whole paragraph for another pass. If that
                // paragraph alone spans >=12s, force its end so the cursor still moves.
                var count = max(1, tail.count - 1)
                var candidate = Self.sample(at: tail[count - 1].end ?? audioEndTime)
                if audioEnd - candidate >= Self.forceSamples {
                    count = tail.count
                    candidate = Self.sample(at: tail[count - 1].end ?? audioEndTime)
                }
                newSeal = max(newSeal, min(audioEnd, candidate))
            }
            clean = false
        }

        let newlySealedCount = final ? tail.count : tail.prefix { Self.ends($0, by: newSeal) }.count
        sealedSegments.append(contentsOf: tail.prefix(newlySealedCount))
        displayedTail = Array(tail.dropFirst(newlySealedCount))
        sealedSampleCount = newSeal
        boundaryIsClean = clean
        return Publication(replacingFrom: oldCount, segments: tail,
                           sealedCount: sealedSegments.count, sealedSampleCount: newSeal,
                           keptDraftAfterEmpty: false)
    }

    private static func ends(_ segment: TranscriptionSegment, by sample: Int) -> Bool {
        guard let end = segment.end else { return false }
        return Self.sample(at: end) <= sample
    }

    private static func sample(at seconds: Double) -> Int {
        // whisper timestamps are centiseconds, but Double multiplication can lie
        // just below the exact sample. Round instead of dropping a boundary sample.
        Int((seconds * Double(sampleRate)).rounded())
    }

    /// Called only for the first paragraph that actually crosses the audio overlap.
    /// No one-character Mandarin matches; Latin matches require whole-word edges.
    static func trimBoundaryOverlap(previous: String, current: String) -> String {
        let punctuation = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let source = Array(previous.trimmingCharacters(in: punctuation).suffix(80))
        let target = Array(current.trimmingCharacters(in: punctuation))
        let maximum = min(source.count, target.count, 80)
        guard maximum >= 2 else { return current }
        func isLatinWord(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy {
                (65...90).contains($0.value) || (97...122).contains($0.value)
                    || (48...57).contains($0.value) || $0.value == 95
            }
        }
        for count in stride(from: maximum, through: 2, by: -1) {
            let suffix = source.suffix(count)
            guard suffix.elementsEqual(target.prefix(count)) else { continue }
            if suffix.contains(where: isLatinWord) {
                let before = source.count - count
                guard (before == 0 || !isLatinWord(source[before - 1])),
                      (count == target.count || !isLatinWord(target[count])) else { continue }
            }
            return String(target.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }
}
