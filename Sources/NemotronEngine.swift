import Foundation
import FluidAudio

/// Runs NVIDIA Nemotron streaming ASR on the Apple Neural Engine via
/// FluidAudio's Core ML port. Loads a model bundle directory (encoder/decoder/
/// joint .mlmodelc + metadata.json + tokenizer.json), feeds 16 kHz mono PCM,
/// and converts the RNNT token timings into TranscriptionSegments.
actor NemotronEngine {
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var loadedDirectory: String?

    func ensureLoaded(directory: URL) async throws {
        if loadedDirectory == directory.path, manager != nil { return }
        await unload()
        let m = StreamingNemotronMultilingualAsrManager()
        try await m.loadModels(from: directory)
        manager = m
        loadedDirectory = directory.path
    }

    func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
        loadedDirectory = nil
    }

    var isLoaded: Bool { manager != nil }

    /// Transcribe a full recording. `language` is a locale/ISO code
    /// ("zh-TW", "ja", "auto", nil = auto-detect).
    func transcribe(samples: [Float],
                    language: String?,
                    onProgress: (@Sendable (Double) -> Void)? = nil,
                    cancellation: TranscriptionCancellation? = nil) async throws -> TranscriptionResult {
        try cancellation?.checkCancellation()
        guard let manager else {
            throw TranscriptionError.processFailed("Nemotron model not loaded")
        }
        await manager.reset()
        await manager.setLanguage(normalizedLanguage(language))

        // Feed in 5 s slices so long files report progress while the encoder runs.
        let sliceSamples = 5 * 16_000
        var offset = 0
        while offset < samples.count {
            try cancellation?.checkCancellation()
            let end = min(offset + sliceSamples, samples.count)
            _ = try await manager.process(samples: Array(samples[offset..<end]))
            offset = end
            if let onProgress {
                let fraction = min(0.98, Double(offset) / Double(samples.count))
                DispatchQueue.main.async { onProgress(fraction) }
            }
        }

        let (text, timings) = try await manager.finishWithTokenTimings()
        try cancellation?.checkCancellation()
        let detected = await manager.detectedLanguage()
        await manager.reset()

        var segments = Self.makeSegments(from: timings)
        let chinese = Self.baseLanguageCode(detected) == "zh" || language == "zh"
        func normalize(_ text: String) -> String {
            chinese ? (text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text) : text
        }
        let trimmedText = normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
        segments = segments.map { TranscriptionSegment(start: $0.start, end: $0.end, text: normalize($0.text)) }
        if segments.isEmpty && !trimmedText.isEmpty {
            segments = [TranscriptionSegment(start: 0,
                                             end: Double(samples.count) / 16_000.0,
                                             text: trimmedText)]
        }
        return TranscriptionResult(text: trimmedText,
                                   segments: segments,
                                   detectedLanguage: Self.baseLanguageCode(detected))
    }

    /// Transcribe a short chunk (live transcription). Times are relative to the
    /// start of the chunk, matching the whisper transcribeChunk contract.
    func transcribeChunk(samples: [Float]) async throws -> TranscriptionResult {
        guard let manager else {
            throw TranscriptionError.processFailed("Nemotron model not loaded")
        }
        await manager.reset()
        _ = try await manager.process(samples: samples)
        let (text, timings) = try await manager.finishWithTokenTimings()
        await manager.reset()

        var segments = Self.makeSegments(from: timings)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segments.isEmpty && !trimmedText.isEmpty {
            segments = [TranscriptionSegment(start: 0,
                                             end: Double(samples.count) / 16_000.0,
                                             text: trimmedText)]
        }
        return TranscriptionResult(text: trimmedText, segments: segments)
    }

    // MARK: - Language codes

    /// The prompt dictionary keys are locale codes ("zh-CN", "ja-JP"). Bare
    /// codes fall back inside FluidAudio; only "auto"/empty needs mapping to nil.
    private func normalizedLanguage(_ language: String?) -> String? {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else { return nil }
        return language
    }

    /// "zh-CN" → "zh" to match the ISO-639-1 codes whisper reports.
    private static func baseLanguageCode(_ locale: String?) -> String? {
        guard let locale, !locale.isEmpty else { return nil }
        return locale.split(separator: "-").first.map { $0.lowercased() }
    }

    // MARK: - Segmentation

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    /// Silence gap between tokens that forces a new segment.
    private static let gapThreshold: TimeInterval = 1.5
    /// Hard cap so a segment never grows unreadably long.
    private static let maxSegmentDuration: TimeInterval = 30

    /// Group per-token timings into sentence-like segments: break after
    /// sentence-final punctuation, on long silences, or at the duration cap.
    static func makeSegments(from timings: [TokenTiming]) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        var pieceTexts: [String] = []
        var segmentStart: TimeInterval = 0
        var segmentEnd: TimeInterval = 0

        func closeSegment() {
            let text = pieceTexts.joined()
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptionSegment(start: segmentStart, end: segmentEnd, text: text))
            }
            pieceTexts.removeAll()
        }

        for (index, timing) in timings.enumerated() {
            if pieceTexts.isEmpty {
                segmentStart = timing.startTime
            }
            pieceTexts.append(timing.token)
            segmentEnd = max(segmentEnd, timing.endTime)

            let endsSentence = timing.token.trimmingCharacters(in: .whitespaces).last
                .map { sentenceEnders.contains($0) } ?? false
            let nextGap: TimeInterval
            if index + 1 < timings.count {
                nextGap = timings[index + 1].startTime - timing.endTime
            } else {
                nextGap = 0
            }
            let tooLong = segmentEnd - segmentStart >= maxSegmentDuration

            if endsSentence || nextGap > gapThreshold || tooLong {
                closeSegment()
            }
        }
        closeSegment()
        return segments
    }
}
