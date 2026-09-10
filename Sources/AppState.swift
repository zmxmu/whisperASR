import Foundation
import Observation
import os

@MainActor
@Observable
class AppState {
    var items: [TranscriptionItem] = []
    var selectedItemID: UUID?

    // Live transcription state
    var liveSegments: [TranscriptionSegment] = [] {
        didSet { advanceLiveTextRevision() }
    }
    private(set) var liveTextRevision: UInt64 = 0
    private(set) var liveTextSourceRevision: UInt64?
    private(set) var liveTextDirtyFrom: Int?
    @ObservationIgnored private var nextTextDirtyFrom: Int?

    private func advanceLiveTextRevision() {
        liveTextSourceRevision = liveTextRevision
        liveTextDirtyFrom = nextTextDirtyFrom
        nextTextDirtyFrom = nil
        liveTextRevision &+= 1
    }
    var isLiveTranscribing = false
    var enableLiveTranscription = true

    // Inline error banners surfaced in RecordingView. Nil when no error.
    var liveError: String?
    var liveTranslationError: String?

    /// A short-lived, auto-dismissing toast for translation errors in the main
    /// window (e.g. expired/invalid API key, failed API call). Deduplicated and
    /// rate-limited so a stream of identical failures can't spam the user.
    var transientToast: String?
    private var toastDismissTask: Task<Void, Never>?
    /// Monotonic-ish marker for the last toast shown, used to suppress repeats.
    private var lastToastText: String?

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = [] {
        didSet { advanceLiveTextRevision() }
    }
    var enableLiveTranslation = false
    /// User-controlled pause for live translation (e.g. the speaker switched to
    /// the listener's native language). Distinct from `translationAuthPaused`,
    /// which is an error-driven stop. While paused, no API calls are made; on
    /// resume, segments spoken during the pause are skipped so only new speech
    /// is translated.
    var liveTranslationPaused = false
    private var liveTranslatedSourceTexts: [String] = []
    private var liveSealedSegmentCount = 0
    private var translationNextIndex = 0
    private var translationEpoch: UInt64 = 0
    private var translationResumeTime = 0.0
    private var liveTranslationLanguage: String?

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var fileTranscriptionTask: Task<Void, Never>?
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    private var liveSessionID: UUID?
    private weak var liveRecorder: AudioRecorder?
    private var finishRequested = false
    private var liveNeedsFilePass = false
    private(set) var isFinishingRecording = false
    private var translationFailureCount = 0
    private var translationAuthPaused = false
    private var lastAutoSaveTime: Date = .distantPast
    private var lastRecoveryRevision: UInt64?
    @ObservationIgnored private let recoveryURL: URL
    @ObservationIgnored private let recoverySaveRunning = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let recoveryQueue = DispatchQueue(label: "WhisperASR.recovery", qos: .utility)

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30
    /// When speech runs continuously past this without a pause (12s at 16kHz), force a chunk cut at
    /// the live tail rather than waiting longer. Kept well under `maxChunkSamples` so the live tail
    /// is always transcribed and no audio is silently dropped.
    private static let forceChunkSamples = 16000 * 12

    init(restoreStoredItems: Bool = true, recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL ?? Self.liveRecoveryURL
        items = restoreStoredItems ? TranscriptionStore.loadAll() : []
        selectedItemID = items.first?.id
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
        // Share the single loaded model with the OpenAI-compatible API server and
        // start it if the user left it enabled.
        Task { @MainActor [service] in
            APIServer.shared.attach(service: service)
            if UserDefaults.standard.bool(forKey: APIServer.enabledKey) {
                APIServer.shared.start()
            }
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    func addFile(url: URL) {
        guard !items.contains(where: { $0.fileURL == url }) else {
            selectedItemID = items.first { $0.fileURL == url }?.id
            return
        }

        let item = TranscriptionItem(fileURL: url)
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        item.segments = []
        item.fullText = ""
        item.progress = 0
        item.translatedSegments = []
        item.translationLanguage = nil
        enqueueTranscription(for: item)
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Preserve the file extension
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"

        // Rename the actual file on disk; only adopt the new URL if the move
        // succeeded (moveItem also fails when the destination already exists).
        // Items without an audio file (e.g. recovered transcripts) just get a
        // new display name.
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        if newURL != item.fileURL, FileManager.default.fileExists(atPath: item.fileURL.path) {
            do {
                try FileManager.default.moveItem(at: item.fileURL, to: newURL)
            } catch {
                Task { @MainActor in
                    self.showToast("Couldn't rename \"\(item.fileName)\": \(error.localizedDescription)")
                }
                return
            }
            item.fileURL = newURL
        }
        item.fileName = nameWithExt
        TranscriptionStore.save(item)
    }

    /// Add a file with pre-existing live transcription results (skip re-transcription).
    @discardableResult
    func addFileWithLiveResults(url: URL, segments: [TranscriptionSegment], fullText: String,
                                translatedSegments: [String] = [], translationLanguage: String? = nil) -> TranscriptionItem {
        let item = TranscriptionItem(fileURL: url)
        item.segments = segments
        item.fullText = fullText
        item.translatedSegments = translatedSegments
        item.translationLanguage = translationLanguage
        item.status = .completed
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        return item
    }

    /// Stop live transcription and the recorder, then file the finished recording.
    /// Shared by the Finish Recording button and the Zoom meeting-ended flow.
    /// If the audio file failed to save but live transcription produced a
    /// transcript, the transcript is kept as an audio-less item instead of
    /// being silently dropped with the recording.
    func finishRecording(recorder: AudioRecorder) async {
        guard !isFinishingRecording else { return }
        isFinishingRecording = true
        defer { isFinishingRecording = false }

        // Stop producers and drain their serial callback queue before taking the final PCM view.
        // The live worker remains alive while AVAssetWriter finishes.
        let url = await recorder.stopRecording(preservePCM: true)
        finishRequested = true
        await liveTranscriptionTask?.value

        // Give the final sealed batch a short opportunity to finish, but never make
        // saving audio depend indefinitely on network/auth availability.
        if enableLiveTranslation && !liveTranslationPaused && !translationAuthPaused {
            enqueueLiveTranslation()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !Task.isCancelled, liveTranslationTask != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if enableLiveTranslation && !liveTranslationPaused && translationNextIndex < liveSealedSegmentCount {
            showToast("Recording saved with partial translation. Use Translate on the saved item to finish it.")
        }

        let segments = liveSegments
        let fullText = segments.map(\.text).joined()
        let translations = liveTranslatedSegments
        let lang = translations.contains(where: { !$0.isEmpty }) ? liveTranslationLanguage : nil
        var saved = false
        if let url {
            if !segments.isEmpty && !liveNeedsFilePass {
                let item = addFileWithLiveResults(url: url, segments: segments, fullText: fullText,
                    translatedSegments: translations, translationLanguage: lang)
                saved = TranscriptionStore.save(item)
            } else {
                // Evicted PCM / timed-out inference cannot be called a completed transcript.
                // Keep provisional text visible while a full-file pass repairs the missing audio.
                let item = TranscriptionItem(fileURL: url)
                item.segments = segments
                item.fullText = fullText
                item.translatedSegments = translations
                item.translationLanguage = lang
                items.insert(item, at: 0)
                selectedItemID = item.id
                saved = TranscriptionStore.save(item)
                enqueueTranscription(for: item)
                if liveNeedsFilePass {
                    showToast("Live transcription was incomplete. The saved audio is queued for a full transcription.")
                }
            }
        } else if !segments.isEmpty {
            let item = addFileWithLiveResults(
                url: URL(fileURLWithPath: "/unsaved-recording-\(UUID().uuidString)"),
                segments: segments, fullText: fullText,
                translatedSegments: translations, translationLanguage: lang)
            item.fileName = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)) (audio not saved)"
            if liveNeedsFilePass { item.status = .failed("Audio could not be saved; recovered live text may be incomplete.") }
            saved = TranscriptionStore.save(item)
        }
        // Never erase recovery data after a failed durable save.
        if !saved && !segments.isEmpty {
            autoSaveLiveTranscription()
            showToast("Couldn't save the transcript item. Live recovery data has been retained.")
        }
        resetLiveSession(removeRecovery: saved)
        recorder.clearTranscriptionBuffer()
        if recorder.state == .saving { recorder.state = .idle }
    }

    // MARK: - Translate Completed Transcription

    /// Show a transient, auto-dismissing toast. Repeats of the same message are
    /// ignored (the timer just restarts) so a continuously-failing translation
    /// queue surfaces the problem once rather than flickering on every retry.
    @MainActor
    func showToast(_ text: String, duration: Duration = .seconds(6)) {
        transientToast = text
        lastToastText = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if it's still the same message we scheduled.
                if self?.lastToastText == text { self?.transientToast = nil }
            }
        }
    }

    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        // @MainActor: `item` is observed by SwiftUI, so every mutation below must
        // land on the main actor; only the translation API calls suspend off it.
        Task { @MainActor in
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let batchSize = 20
            var transientFailures = 0

            batchLoop: for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                do {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch let err as TranslationError {
                    print("[Translation] batch error: \(err)")
                    switch err {
                    case .authFailed, .invalidEndpoint, .unavailable:
                        // Not retriable — stop hammering the API and report it once.
                        self.showToast(err.errorDescription ?? "Translation failed")
                        break batchLoop
                    default:
                        transientFailures += 1
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                    transientFailures += 1
                }
            }

            // Some batches failed transiently (network/server/rate-limit) but we
            // kept going; let the user know the result is incomplete.
            if transientFailures > 0 {
                self.showToast("Translation incomplete — \(transientFailures) section\(transientFailures == 1 ? "" : "s") couldn't be translated. Check your network or API settings.")
            }

            item.isTranslating = false
            TranscriptionStore.save(item)
        }
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        TranscriptionStore.save(item)
    }

    func shutdown() {
        fileTranscriptionTask?.cancel()
        liveTranscriptionTask?.cancel()
        invalidateTranslationWorker()
        service.shutdown()
    }

    func removeItem(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    private func enqueueTranscription(for item: TranscriptionItem) {
        item.status = .pending
        if !isTranscribing {
            startNextTranscription()
        }
    }

    private func startNextTranscription() {
        guard let item = items.first(where: { $0.status == .pending }) else {
            isTranscribing = false
            return
        }
        isTranscribing = true
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()
        let recognitionLanguage = RecognitionLanguageMode.current.whisperLanguage

        fileTranscriptionTask = Task { [weak self, service] in
            guard let self else { return }
            while !Task.isCancelled, items.contains(where: { $0.id == item.id }) {
                do {
                    let result = try await service.transcribe(
                        fileURL: item.fileURL, language: recognitionLanguage
                    ) { progress in
                        Task { @MainActor in
                            item.status = .transcribing
                            item.progress = progress
                        }
                    }
                    guard !Task.isCancelled, items.contains(where: { $0.id == item.id }) else { break }
                    if !item.translatedSegments.isEmpty {
                        let sameSources = item.segments.count == result.segments.count &&
                            zip(item.segments, result.segments).allSatisfy { $0.text == $1.text }
                        if !sameSources {
                            item.translatedSegments = []
                            item.translationLanguage = nil
                            showToast("The full transcription changed the source segments. Use Translate on the saved item to update its translation.")
                        }
                    }
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                    TranscriptionStore.save(item)
                    break
                } catch let error as TranscriptionExecutionError where Self.isWaitingForService(error) {
                    guard !Task.isCancelled, items.contains(where: { $0.id == item.id }) else { break }
                    // A native timeout may still own the GPU. Preserve queued work;
                    // do not cascade a temporary busy error through every pending file.
                    if item.status != .pending {
                        item.status = .pending
                        TranscriptionStore.save(item)
                    }
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    guard !Task.isCancelled, items.contains(where: { $0.id == item.id }) else { break }
                    item.status = .failed(error.localizedDescription)
                    TranscriptionStore.save(item)
                    break
                }
            }
            if !Task.isCancelled { startNextTranscription() }
        }
    }

    // MARK: - Live Transcription During Recording

    /// All publication and lifecycle state is main-actor isolated. Only bounded PCM windows
    /// cross into the serialized native executor; an old session can never publish into a new one.
    func startLiveTranscription(recorder: AudioRecorder) {
        guard liveSessionID == nil, !isFinishingRecording else { return }
        let session = UUID()
        liveSessionID = session
        liveRecorder = recorder
        finishRequested = false
        liveNeedsFilePass = false
        liveSegments = []
        liveTranslatedSegments = []
        liveTranslatedSourceTexts = []
        liveSealedSegmentCount = 0
        translationNextIndex = 0
        translationResumeTime = 0
        liveTranslationLanguage = nil
        liveError = nil
        liveTranslationError = nil
        translationFailureCount = 0
        translationAuthPaused = false
        liveTranslationPaused = false
        lastAutoSaveTime = .distantPast
        lastRecoveryRevision = nil
        isLiveTranscribing = true
        let language = RecognitionLanguageMode.current.whisperLanguage

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if session == liveSessionID { isLiveTranscribing = false }
            }
            do {
                while !Task.isCancelled, session == liveSessionID {
                    do {
                        try await service.preloadModel()
                        break
                    } catch let error as TranscriptionExecutionError where Self.isWaitingForService(error) {
                        if finishRequested { liveNeedsFilePass = true; return }
                        liveError = "Waiting for the transcription service. Audio recording continues."
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                guard session == liveSessionID, !Task.isCancelled else { return }
                liveError = nil
                await runLiveLoop(recorder: recorder, language: language, session: session)
            } catch {
                guard session == liveSessionID, !Task.isCancelled else { return }
                liveNeedsFilePass = true
                liveError = "Couldn't load transcription model: \(error.localizedDescription)"
            }
        }
    }

    private func runLiveLoop(recorder: AudioRecorder, language: String?, session: UUID) async {
        var assembler = LiveTranscriptionAssembler()
        var lastTranscribedEnd = 0
        var lastEmptyAvailableEnd: Int?
        var firstEmptyAvailableEnd: Int?
        var inferenceDuration = 0.0
        defer {
            // A terminal repair transition stops the periodic loop. Persist its last
            // draft now even if the normal 15-second checkpoint is not due yet.
            if liveSessionID == session, !Task.isCancelled, liveNeedsFilePass,
               !liveSegments.isEmpty {
                autoSaveLiveTranscription()
            }
        }

        while !Task.isCancelled, liveSessionID == session {
            // Flush a last revision even when subsequent audio is silent or capture is idle.
            throttledAutoSave()
            let minimumNewSamples = Int(min(2, max(0.75, inferenceDuration * 0.5)) * 16000)
            // Cheap admission only: the actual window still comes from one atomic snapshot.
            // Avoid copying up to 1.9 MB on every 200 ms tick while waiting for more audio.
            let capturedEnd = recorder.accumulatedSampleCount
            if !finishRequested {
                let waitingAfterEmpty = lastEmptyAvailableEnd.map {
                    capturedEnd - $0 < minimumNewSamples
                } ?? false
                let fullWindow = capturedEnd - assembler.tailStart >= Self.maxChunkSamples
                if waitingAfterEmpty || capturedEnd - assembler.sealedSampleCount < 8000 ||
                    (!fullWindow && capturedEnd - lastTranscribedEnd < minimumNewSamples) {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
            }
            let snapshot = recorder.transcriptionSnapshot(
                from: assembler.tailStart, maximumCount: Self.maxChunkSamples)
            if snapshot.wasEvicted && assembler.sealedSampleCount < snapshot.oldest {
                liveNeedsFilePass = true
                liveError = "Transcription fell behind; missing audio will be transcribed from the saved recording."
                if firstEmptyAvailableEnd != nil, !assembler.displayedTail.isEmpty {
                    // Capture may outrun the retry budget while inference is suspended.
                    // Do not erase the retained draft when its PCM is no longer present.
                    break
                }
                publishLive(assembler.skip(to: snapshot.start))
            }
            let finalWindow = finishRequested && snapshot.end == snapshot.availableEnd
            if finishRequested && snapshot.availableEnd <= assembler.sealedSampleCount { break }
            if snapshot.samples.isEmpty ||
                (!finishRequested && snapshot.samples.count < Self.maxChunkSamples &&
                    (snapshot.end - assembler.sealedSampleCount < 8000 ||
                    snapshot.end - lastTranscribedEnd < minimumNewSamples)) {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            // Scan exactly the same immutable window that is decoded, never a second buffer read.
            // Do not throw away an already displayed tail on a low-energy revision.
            if snapshot.rms <= 0.001 && assembler.displayedTail.isEmpty {
                publishLive(assembler.skip(to: snapshot.end))
                lastTranscribedEnd = snapshot.end
                recorder.trimSamples(upTo: assembler.tailStart)
                if finalWindow { break }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            let inferenceStart = ContinuousClock.now
            do {
                // Whisper requires a meaningful input window even for a sub-second final tail.
                // Padding is not allowed to extend published timestamps beyond captured audio.
                var samples = snapshot.samples
                if samples.count < 16000 { samples += Array(repeating: 0, count: 16000 - samples.count) }
                let result = try await service.transcribeChunk(samples: samples, language: language)
                guard !Task.isCancelled, liveSessionID == session else { return }
                if finalWindow && result.segments.isEmpty && !assembler.displayedTail.isEmpty {
                    // A voiced final window without decoder output is not proof of silence.
                    // Preserve the displayed draft and repair from the durable audio file.
                    liveNeedsFilePass = true
                    break
                }
                let elapsed = inferenceStart.duration(to: .now).components
                inferenceDuration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                lastTranscribedEnd = snapshot.end
                let offset = Double(snapshot.start) / 16000
                let end = Double(snapshot.end) / 16000
                let segments = result.segments.compactMap { segment -> TranscriptionSegment? in
                    let start = max(offset, min(end, segment.start + offset))
                    guard start < end else { return nil }
                    return TranscriptionSegment(start: start,
                        end: max(start, min(end, (segment.end ?? Double(samples.count) / 16000) + offset)),
                        text: segment.text)
                }
                let hadDisplayedTail = !assembler.displayedTail.isEmpty
                let publication = assembler.apply(
                    result: segments, audioStart: snapshot.start, audioEnd: snapshot.end,
                    silenceCut: snapshot.lastSilenceCut(searchFrom: assembler.sealedSampleCount),
                    force: snapshot.end - assembler.sealedSampleCount >= Self.forceChunkSamples,
                    final: finalWindow)
                if finalWindow && publication.segments.isEmpty && hadDisplayedTail {
                    // Output may contain only look-behind segments and become empty after
                    // reconciliation. Keep the last visible draft at Finish in that case.
                    liveNeedsFilePass = true
                    break
                }
                if publication.keptDraftAfterEmpty {
                    // A retained draft makes no cursor progress. While recording, allow a
                    // transient empty revision to recover, but only for 12 more captured
                    // seconds. During Finish there is no future audio to wait for at all.
                    // Exit to durable-file repair instead of dropping/promoting uncertain
                    // text or repeatedly decoding the same backlogged 30-second window.
                    let retryBudgetExhausted = firstEmptyAvailableEnd.map {
                        snapshot.availableEnd - $0 >= Self.forceChunkSamples
                    } ?? false
                    if finishRequested || retryBudgetExhausted {
                        liveNeedsFilePass = true
                        liveError = "Live inference stopped because the draft could not be confirmed. Audio recording continues; the saved audio will be transcribed after recording."
                        break
                    }
                    firstEmptyAvailableEnd = firstEmptyAvailableEnd ?? snapshot.availableEnd
                    lastEmptyAvailableEnd = snapshot.availableEnd
                } else {
                    firstEmptyAvailableEnd = nil
                    lastEmptyAvailableEnd = nil
                }
                publishLive(publication)
                if !liveNeedsFilePass { liveError = nil }
                recorder.trimSamples(upTo: assembler.tailStart)
                throttledAutoSave()
                enqueueLiveTranslation()
                if finalWindow { break }
            } catch let error as TranscriptionExecutionError where Self.isWaitingForService(error) {
                guard !Task.isCancelled, liveSessionID == session else { return }
                if finishRequested { liveNeedsFilePass = true; break }
                liveError = "Waiting for the transcription service. Audio recording continues."
                try? await Task.sleep(for: .seconds(1))
                continue
            } catch {
                guard !Task.isCancelled, liveSessionID == session else { return }
                liveNeedsFilePass = true
                liveError = "Live inference stopped: \(error.localizedDescription). The saved audio will be transcribed after recording."
                // A timed-out native call may still own the GPU. Do not queue retries or
                // pretend that missing PCM is silence. Final filing takes the full-file path.
                break
            }

            if !finishRequested {
                // A 2-second ceiling trades power for bounded latency; it is NOT a fixed 2/3
                // duty cycle on a slow model. Skip idle while a complete window is backlogged.
                let backlog = recorder.accumulatedSampleCount - lastTranscribedEnd
                if backlog < Self.forceChunkSamples {
                    try? await Task.sleep(for: .seconds(min(2, max(0.35, inferenceDuration * 0.5))))
                }
            }
        }
    }

    private func publishLive(_ publication: LiveTranscriptionAssembler.Publication) {
        let oldTail = liveSegments[publication.replacingFrom...]
        let unchanged = oldTail.count == publication.segments.count &&
            zip(oldTail, publication.segments).allSatisfy {
                $0.start == $1.start && $0.end == $1.end && $0.text == $1.text
            }
        if !unchanged {
            nextTextDirtyFrom = publication.replacingFrom
            liveSegments.replaceSubrange(publication.replacingFrom..<liveSegments.count,
                                         with: publication.segments)
        }
        liveSealedSegmentCount = publication.sealedCount
    }

    nonisolated private static func isWaitingForService(_ error: TranscriptionExecutionError) -> Bool {
        switch error {
        case .busy, .queuedTimedOut: return true
        case .timedOut: return false
        }
    }

    /// Cancel discards the current session; Finish uses the drain path above instead.
    func stopLiveTranscription() {
        guard !isFinishingRecording else { return }
        resetLiveSession(removeRecovery: true)
    }

    private func resetLiveSession(removeRecovery: Bool) {
        liveSessionID = nil
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        invalidateTranslationWorker()
        liveRecorder = nil
        finishRequested = false
        translationFailureCount = 0
        translationAuthPaused = false
        isLiveTranscribing = false
        liveError = nil
        liveTranslationError = nil
        liveSegments = []
        liveTranslatedSegments = []
        liveTranslatedSourceTexts = []
        liveSealedSegmentCount = 0
        translationNextIndex = 0
        liveTranslationLanguage = nil
        enableLiveTranslation = false
        liveTranslationPaused = false
        if removeRecovery { removeLiveRecoveryFile() }
    }

    // MARK: - Live Transcription Auto-Save (crash recovery)

    nonisolated private static var liveRecoveryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("live_recovery.json")
    }

    private struct LiveRecoveryData: Codable {
        let segments: [TranscriptionSegment]
        let fullText: String?
        let translatedSegments: [String]
        let translationLanguage: String?
        let savedAt: Date
    }

    /// Only auto-save at most every 15 seconds to avoid JSON serialization overhead.
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard lastRecoveryRevision != liveTextRevision,
              !recoverySaveRunning.withLock({ $0 }), now.timeIntervalSince(lastAutoSaveTime) >= 15 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    /// Persist current live transcription to a recovery file so data survives a hang or crash.
    @MainActor
    private func autoSaveLiveTranscription() {
        recoverySaveRunning.withLock { $0 = true }
        let segments = liveSegments
        let translations = liveTranslatedSegments
        let revision = liveTextRevision
        let session = liveSessionID
        let lang = liveTranslationLanguage
        let url = recoveryURL

        // Write on a background queue to avoid blocking the main thread
        let running = recoverySaveRunning
        Self.recoveryQueue.async {
            defer { running.withLock { $0 = false } }
            let data = LiveRecoveryData(
                segments: segments, fullText: nil,
                translatedSegments: translations, translationLanguage: lang,
                savedAt: Date()
            )
            let encoder = JSONEncoder()
            guard let json = try? encoder.encode(data) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try json.write(to: url, options: .atomic)
                Task { @MainActor [weak self] in
                    if self?.liveSessionID == session { self?.lastRecoveryRevision = revision }
                }
            } catch {
                print("[LiveRecovery] Save failed: \(error.localizedDescription)")
            }
        }
    }

    private func removeLiveRecoveryFile() {
        // Ordered after any in-flight save, so it cannot recreate a finished session.
        let url = recoveryURL
        Self.recoveryQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: recoveryURL.path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = recoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: recovery.savedAt))"))
        item.segments = recovery.segments
        item.fullText = recovery.fullText ?? recovery.segments.map(\.text).joined()
        item.translatedSegments = recovery.translatedSegments
        item.translationLanguage = recovery.translationLanguage
        item.status = .completed
        item.fileName = "Recovered \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
        items.insert(item, at: 0)
        selectedItemID = item.id
        if TranscriptionStore.save(item) { removeLiveRecoveryFile() }
    }

    // MARK: - Live Translation

    func setLiveTranslationPaused(_ paused: Bool) {
        guard liveTranslationPaused != paused else { return }
        liveTranslationPaused = paused
        invalidateTranslationWorker()
        if !paused {
            // Use captured time, not the mutable segment count: late finalization of speech
            // from the pause must not slip into a resumed request.
            translationResumeTime = Double(liveRecorder?.accumulatedSampleCount ?? 0) / 16000
            enqueueLiveTranslation()
        }
    }

    private func invalidateTranslationWorker() {
        translationEpoch &+= 1
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
    }

    private func translationWorkerIsCurrent(_ epoch: UInt64) -> Bool {
        !Task.isCancelled && epoch == translationEpoch && liveSessionID != nil &&
            enableLiveTranslation && !liveTranslationPaused && !translationAuthPaused
    }

    /// Translate only the immutable ASR prefix, with a monotonic cursor and one bounded
    /// request in flight. No retained cumulative history snapshot or O(n) dirty scan.
    private func enqueueLiveTranslation() {
        guard liveTranslationTask == nil, translationWorkerIsCurrent(translationEpoch),
              translationNextIndex < liveSealedSegmentCount else { return }
        let epoch = translationEpoch
        liveTranslationTask = Task { [weak self] in
            await self?.drainTranslationQueue(epoch: epoch)
        }
    }

    private func drainTranslationQueue(epoch: UInt64) async {
        defer {
            // An old canceled worker must not clear the handle of its replacement.
            if epoch == translationEpoch { liveTranslationTask = nil }
        }
        while translationWorkerIsCurrent(epoch), translationNextIndex < liveSealedSegmentCount {
            if translationFailureCount > 0 {
                let milliseconds = Self.translationRetryDelayMilliseconds(failureCount: translationFailureCount)
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard translationWorkerIsCurrent(epoch) else { return }
            }
            let target = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
            guard !target.isEmpty else { return }
            if let previous = liveTranslationLanguage, previous != target {
                translationAuthPaused = true
                liveTranslationError = "Translation language changed. Start a new recording to avoid mixed-language results."
                return
            }
            liveTranslationLanguage = target

            while translationNextIndex < liveSealedSegmentCount,
                  liveSegments[translationNextIndex].start < translationResumeTime {
                nextTextDirtyFrom = translationNextIndex
                liveTranslatedSegments.append("")
                liveTranslatedSourceTexts.append(liveSegments[translationNextIndex].text)
                translationNextIndex += 1
            }
            let start = translationNextIndex
            let end = min(start + 24, liveSealedSegmentCount)
            guard end > start else { return }
            let texts = liveSegments[start..<end].map { $0.text.trimmingCharacters(in: .whitespaces) }
            let context: [(original: String, translated: String)] = (max(0, start - 2)..<start).compactMap { i in
                guard i < liveTranslatedSegments.count, !liveTranslatedSegments[i].isEmpty else { return nil }
                return (liveTranslatedSourceTexts[i], liveTranslatedSegments[i])
            }
            do {
                let translated = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: texts, targetLanguage: target, previousTranslations: context)
                guard translationWorkerIsCurrent(epoch) else { return }
                guard UserDefaults.standard.string(forKey: "targetLanguage") == target else {
                    liveTranslationError = "Translation language changed. Restart translation in a new recording to avoid mixed-language results."
                    translationAuthPaused = true
                    return
                }
                guard translated.count == texts.count else {
                    throw NSError(domain: "LiveTranslation", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Translation returned an unexpected segment count."])
                }
                guard end <= liveSealedSegmentCount,
                      liveSegments[start..<end].map({ $0.text.trimmingCharacters(in: .whitespaces) }) == texts else { return }
                nextTextDirtyFrom = start
                liveTranslatedSegments.append(contentsOf: translated)
                liveTranslatedSourceTexts.append(contentsOf: texts)
                translationNextIndex = end
                translationFailureCount = 0
                liveTranslationError = nil
                if isLiveTranscribing {
                    throttledAutoSave()
                } else {
                    // No live loop remains to flush this revision at the next checkpoint.
                    // Save each accepted late batch before a later retry or Pause can
                    // suspend/retire this worker indefinitely.
                    autoSaveLiveTranscription()
                }
            } catch {
                guard translationWorkerIsCurrent(epoch) else { return }
                if let error = error as? TranslationError {
                    switch error {
                    case .authFailed, .invalidEndpoint, .unavailable:
                        translationAuthPaused = true
                        liveTranslationError = error.errorDescription
                        return
                    default: break
                    }
                }
                translationFailureCount = min(translationFailureCount + 1, 32)
                if translationFailureCount >= 3 { liveTranslationError = error.localizedDescription }
            }
        }
    }

    nonisolated static func translationRetryDelayMilliseconds(failureCount: Int) -> Int {
        // Clamp before subtraction, shift and multiply, including Int.max test inputs.
        let bounded = min(7, max(1, failureCount))
        return min(30_000, 500 * (1 << (bounded - 1)))
    }
}
