// Integration checks: compile the REAL AppState, models, PCM buffer and assembler.
// Only hardware/network/durable item storage are stubbed below. No real model or
// user transcription directory is used; each session has a temporary recovery URL.
// swiftc -parse-as-library Sources/Models.swift Sources/LiveAudioBuffer.swift Sources/LiveTranscriptionAssembler.swift Sources/CancellationSupport.swift Sources/AppState.swift Tests/LiveSessionChecks.swift -o /tmp/LiveSessionChecks && /tmp/LiveSessionChecks
import Foundation
import Observation

private actor ServiceScenario {
    var chunks: [[Float]] = []
    var files: [URL] = []
    var holdPreload = false
    var holdFirstChunk = false
    var failChunk: Int?
    var busyChunk: Int?
    var queuedTimeoutChunk: Int?
    var firstResultIsShort = false
    var emptyChunk: Int?
    var additionalEmptyChunks: [Int] = []
    var emptyFromChunk: Int?
    var overlapOnlyChunk: Int?
    var decodeCallBudget: Int?
    private var decodeBudgetFailures = 0
    private var preload: CheckedContinuation<Void, Never>?
    private var firstChunk: CheckedContinuation<Void, Never>?
    private var file: CheckedContinuation<TranscriptionResult, Error>?

    func configure(holdPreload: Bool = false, holdFirstChunk: Bool = false,
                   failChunk: Int? = nil, firstResultIsShort: Bool = false,
                   emptyChunk: Int? = nil, overlapOnlyChunk: Int? = nil,
                   busyChunk: Int? = nil, queuedTimeoutChunk: Int? = nil,
                   emptyFromChunk: Int? = nil, decodeCallBudget: Int? = nil,
                   additionalEmptyChunks: [Int] = []) {
        self.holdPreload = holdPreload
        self.holdFirstChunk = holdFirstChunk
        self.failChunk = failChunk
        self.busyChunk = busyChunk
        self.queuedTimeoutChunk = queuedTimeoutChunk
        self.firstResultIsShort = firstResultIsShort
        self.emptyChunk = emptyChunk
        self.additionalEmptyChunks = additionalEmptyChunks
        self.emptyFromChunk = emptyFromChunk
        self.overlapOnlyChunk = overlapOnlyChunk
        self.decodeCallBudget = decodeCallBudget
    }
    func preloadModel() async {
        if holdPreload { await withCheckedContinuation { preload = $0 } }
    }
    func releasePreload() { preload?.resume(); preload = nil; holdPreload = false }
    func releaseFirstChunk() { firstChunk?.resume(); firstChunk = nil }
    func preloadIsWaiting() -> Bool { preload != nil }
    func chunkCount() -> Int { chunks.count }
    func recordedChunks() -> [[Float]] { chunks }
    func fileCount() -> Int { files.count }
    func decodeBudgetFailureCount() -> Int { decodeBudgetFailures }

    func transcribeChunk(_ samples: [Float]) async throws -> TranscriptionResult {
        let index = chunks.count
        if let decodeCallBudget, index >= decodeCallBudget {
            // Bound a regressed no-progress loop so this integration test fails
            // deterministically instead of hanging or invoking thousands of calls.
            decodeBudgetFailures += 1
            throw TranscriptionError.processFailed("Fixture decode-call budget exceeded")
        }
        chunks.append(samples)
        if index == 0 && holdFirstChunk {
            // Deliberately ignore Task cancellation: AppState's session/epoch guards
            // must reject late results even from a non-cooperative dependency.
            await withCheckedContinuation { firstChunk = $0 }
        }
        if failChunk == index { throw TranscriptionExecutionError.timedOut }
        if busyChunk == index { throw TranscriptionExecutionError.busy }
        if queuedTimeoutChunk == index { throw TranscriptionExecutionError.queuedTimedOut }
        if emptyChunk == index || additionalEmptyChunks.contains(index) {
            return TranscriptionResult(text: "", segments: [])
        }
        if let emptyFromChunk, index >= emptyFromChunk {
            return TranscriptionResult(text: "", segments: [])
        }
        if overlapOnlyChunk == index {
            let segment = TranscriptionSegment(start: 0, end: 1, text: "词12")
            return TranscriptionResult(text: segment.text, segments: [segment])
        }
        if index == 0 && firstResultIsShort {
            let segment = TranscriptionSegment(start: 0, end: 0.2, text: "短结果")
            return TranscriptionResult(text: segment.text, segments: [segment])
        }
        return Self.recognizeMarkers(samples)
    }

    func transcribeFile(_ url: URL) async throws -> TranscriptionResult {
        files.append(url)
        return try await withCheckedThrowingContinuation { file = $0 }
    }
    func releaseFile(result: TranscriptionResult? = nil) {
        let segment = TranscriptionSegment(start: 0, end: 3, text: "完整录音")
        file?.resume(returning: result ?? TranscriptionResult(text: segment.text, segments: [segment]))
        file = nil
    }
    func failFile() {
        file?.resume(throwing: TranscriptionError.processFailed("Fixture full-file failure"))
        file = nil
    }

    // The stub returns known words for synthetic constant-amplitude speech runs.
    // This models recognition output only; all session/window/seal logic is real.
    private static func recognizeMarkers(_ samples: [Float]) -> TranscriptionResult {
        var result: [TranscriptionSegment] = []
        var start = 0
        while start < samples.count {
            let value = samples[start]
            var end = start + 1
            while end < samples.count && samples[end] == value { end += 1 }
            if value > 0 {
                result.append(TranscriptionSegment(start: Double(start) / 16000,
                    end: Double(end) / 16000, text: "词\(Int((value * 100).rounded()))"))
            }
            start = end
        }
        return TranscriptionResult(text: result.map(\.text).joined(), segments: result)
    }
}

private actor TranslationScenario {
    var requests: [[String]] = []
    private var waiting: [Int: CheckedContinuation<[String], Error>] = [:]
    func translate(_ texts: [String]) async throws -> [String] {
        let index = requests.count
        requests.append(texts)
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func count() -> Int { requests.count }
    func request(_ index: Int) -> [String] { requests[index] }
    func complete(_ index: Int, prefix: String) {
        waiting.removeValue(forKey: index)?.resume(returning: requests[index].map { prefix + $0 })
    }
    func completeAll() {
        let pending = waiting
        waiting.removeAll()
        for (index, continuation) in pending {
            continuation.resume(returning: requests[index].map { "CLEANUP" + $0 })
        }
    }
}

@MainActor
private enum StubEnvironment {
    static var service = ServiceScenario()
    static var translation = TranslationScenario()
}

// Hardware, network and durable-store boundaries used by the actual AppState.
final class TranscriptionService: @unchecked Sendable {
    private let scenario: ServiceScenario
    @MainActor init() { scenario = StubEnvironment.service }
    func preloadModel() async throws { await scenario.preloadModel() }
    func transcribeChunk(samples: [Float], language: String? = nil,
                         timeoutSeconds: TimeInterval? = nil) async throws -> TranscriptionResult {
        try await scenario.transcribeChunk(samples)
    }
    func transcribe(fileURL: URL, language: String? = nil, translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try await scenario.transcribeFile(fileURL)
    }
    func shutdown() {}
}

@MainActor @Observable
final class AudioRecorder {
    enum State { case idle, recording, saving }
    var state: State = .recording
    let buffer = LiveAudioBuffer()
    var appendOnStop: [Float] = []
    var stopCalls = 0
    var bufferClears = 0
    let resultURL: URL
    init(url: URL) { resultURL = url }
    var accumulatedSampleCount: Int { buffer.availableRange.upperBound }
    func transcriptionSnapshot(from start: Int, maximumCount: Int) -> LiveAudioSnapshot {
        buffer.snapshot(from: start, maximumCount: maximumCount)
    }
    func trimSamples(upTo sample: Int) { buffer.trim(upTo: sample) }
    func clearTranscriptionBuffer() { bufferClears += 1; buffer.clear() }
    func stopRecording(preservePCM: Bool = false) async -> URL? {
        precondition(preservePCM, "Finish must preserve PCM until its final drain")
        stopCalls += 1
        state = .saving
        buffer.append(appendOnStop)
        appendOnStop = []
        return resultURL
    }
}

@MainActor
enum TranscriptionStore {
    struct Saved {
        let id: UUID
        let status: TranscriptionStatus
        let text: String
        let translations: [String]
        let translationLanguage: String?
    }
    static var saves: [Saved] = []
    static var loadCalls = 0
    static func loadAll() -> [TranscriptionItem] { loadCalls += 1; return [] }
    @discardableResult static func save(_ item: TranscriptionItem) -> Bool {
        saves.append(Saved(id: item.id, status: item.status, text: item.fullText,
                           translations: item.translatedSegments, translationLanguage: item.translationLanguage))
        return true
    }
    static func delete(_ item: TranscriptionItem) {}
}

@MainActor
final class APIServer {
    static let shared = APIServer()
    static let enabledKey = "LiveSessionChecks.serverEnabled"
    func attach(service: TranscriptionService) {}
    func start() {}
}

enum TranslationError: LocalizedError {
    case authFailed, invalidEndpoint, unavailable, transient
    var errorDescription: String? { "Test translation error" }
}
enum TranslationService {
    static func translateSegmentsWithOpenAI(segmentTexts: [String], targetLanguage: String,
        previousTranslations: [(original: String, translated: String)]) async throws -> [String] {
        let scenario = await StubEnvironment.translation
        return try await scenario.translate(segmentTexts)
    }
}

@main @MainActor
struct LiveSessionChecks {
    private static var directory: URL!

    private static func eventually(_ message: String,
                                   condition: () async -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            precondition(ContinuousClock.now < limit, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func speech(_ marker: Int, seconds: Double = 1) -> [Float] {
        Array(repeating: Float(marker) / 100, count: Int(seconds * 16000))
    }
    private static func silent(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * 16000))
    }
    private static func makeSession(_ name: String) -> (AppState, AudioRecorder, ServiceScenario) {
        StubEnvironment.service = ServiceScenario()
        StubEnvironment.translation = TranslationScenario()
        let state = AppState(restoreStoredItems: false,
                             recoveryURL: directory.appendingPathComponent(name + ".json"))
        let recorder = AudioRecorder(url: directory.appendingPathComponent(name + ".m4a"))
        return (state, recorder, StubEnvironment.service)
    }

    static func main() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WhisperASR-LiveSessionChecks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // This executable has its own preferences domain, and the changed value is restored.
        let oldTarget = UserDefaults.standard.object(forKey: "targetLanguage")
        UserDefaults.standard.set("en", forKey: "targetLanguage")
        defer {
            if let oldTarget { UserDefaults.standard.set(oldTarget, forKey: "targetLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "targetLanguage") }
        }

        try await finalTailAfterStop()
        try await drainLongRecording()
        try await fullWindowDoesNotStall()
        try await timedOutLiveUsesFullFile()
        try await emptyFinalPreservesDraft(overlapOnly: false)
        try await emptyFinalPreservesDraft(overlapOnly: true)
        try await emptyFinalBackgroundNoiseDoesNotRepair()
        try await transientEmptyPreservesDraftAndRecovers(overlapOnly: false)
        try await transientEmptyPreservesDraftAndRecovers(overlapOnly: true)
        try await persistentEmptyBacklogFinishesWithoutLooping()
        try await persistentEmptyLiveDegradesBeforeBufferEviction()
        try await successfulRevisionResetsEmptyRecoveryBudget()
        try await retainedDraftSurvivesBufferEviction(lateTranslation: false)
        try await retainedDraftSurvivesBufferEviction(lateTranslation: true)
        try await recoverableAdmissionFailureDoesNotRepair(queuedTimeout: false)
        try await recoverableAdmissionFailureDoesNotRepair(queuedTimeout: true)
        for outcome in FileRepairOutcome.allCases {
            try await fullFileRepairPreservesTranslation(outcome: outcome)
        }
        try await cancelledFinishDoesNotSpinInTranslationGrace()
        try await pausedTranslationCannotPublishIntoReplacement()
        for count in [0, 1, 2, 7, 32, 10_000, Int.max] {
            let delay = AppState.translationRetryDelayMilliseconds(failureCount: count)
            precondition((0...30_000).contains(delay), "Backoff overflowed for \(count)")
        }
        precondition(AppState.translationRetryDelayMilliseconds(failureCount: Int.max) == 30_000)
        precondition(TranscriptionStore.loadCalls == 0, "Tests must not restore real stored items")
        print("PASS: real AppState final 0.2s tail, >30s drain, full-window progress, true timeout/empty-final recovery, empty background-noise final, transient empty/overlap draft recovery, bounded persistent-empty Finish/live fallback and budget reset, retained-draft cap/recovery checkpoints and late translation flush, busy/queued-timeout retry, repair translation retention/invalidation, cancellable finish grace, translation epochs/worker ownership, bounded Int.max backoff")
        print("Temporary recovery fixtures: \(directory.path)")
    }

    private static func finalTailAfterStop() async throws {
        let (state, recorder, service) = makeSession("final-tail")
        await service.configure(holdFirstChunk: true)
        recorder.buffer.append(speech(10) + silent(0.5))
        recorder.appendOnStop = speech(20, seconds: 0.2)
        state.startLiveTranscription(recorder: recorder)
        try await eventually("First inference did not start") { await service.chunkCount() == 1 }
        let finish = Task { await state.finishRecording(recorder: recorder) }
        try await eventually("Recorder did not stop") { recorder.stopCalls == 1 }
        await service.releaseFirstChunk()
        await finish.value
        precondition(state.items.count == 1)
        let item = state.items[0]
        precondition(item.status == .completed && item.fullText == "词10词20")
        precondition(abs((item.segments.last?.end ?? 0) - 1.7) < 0.0001,
                     "Zero padding must not extend final timestamps")
        let chunks = await service.recordedChunks()
        precondition(chunks.count >= 2 && chunks.last?.contains(Float(0.2)) == true,
                     "Final samples produced while stop drains must reach inference")
        let fileCount = await service.fileCount()
        precondition(fileCount == 0)
        precondition(recorder.bufferClears == 1)
    }

    private static func drainLongRecording() async throws {
        let (state, recorder, service) = makeSession("long-drain")
        await service.configure(holdPreload: true)
        for marker in 1...65 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Preload gate not reached") { await service.preloadIsWaiting() }
        let finish = Task { await state.finishRecording(recorder: recorder) }
        try await eventually("Long recording did not stop") { recorder.stopCalls == 1 }
        await service.releasePreload()
        await finish.value
        let chunks = await service.recordedChunks()
        precondition(chunks.count >= 3 && chunks.allSatisfy { $0.count <= 30 * 16000 })
        let item = state.items[0]
        precondition(item.status == .completed && item.segments.count == 65)
        precondition(item.fullText == (1...65).map { "词\($0)" }.joined(),
                     "Stopped audio must drain oldest-first with no omitted middle window")
        precondition(abs((item.segments.last?.end ?? 0) - 65) < 0.0001)
    }

    private static func fullWindowDoesNotStall() async throws {
        let (state, recorder, service) = makeSession("full-window")
        await service.configure(firstResultIsShort: true)
        for marker in 1...32 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        // Stay live: finishRequested must not be the reason the no-new-audio gate opens.
        try await eventually("A complete 30s window stalled after a short decoded paragraph") {
            await service.chunkCount() >= 2
        }
        precondition(recorder.stopCalls == 0)
        await state.finishRecording(recorder: recorder)
        precondition(state.items[0].segments.last?.end == 32)
    }

    private static func timedOutLiveUsesFullFile() async throws {
        let (state, recorder, service) = makeSession("timeout")
        await service.configure(failChunk: 1)
        recorder.buffer.append(speech(10) + silent(0.5))
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial live text missing") { !state.liveSegments.isEmpty }
        recorder.buffer.append(speech(20, seconds: 2))
        try await eventually("Injected live timeout did not stop the worker") {
            !state.isLiveTranscribing && state.liveError != nil
        }
        await state.finishRecording(recorder: recorder)
        try await eventually("Incomplete live transcript did not enqueue full-file repair") {
            await service.fileCount() == 1
        }
        let item = state.items[0]
        precondition(item.status != .completed && item.fullText.contains("词10"),
                     "Incomplete live draft must not be falsely marked complete")
        await service.releaseFile()
        try await eventually("Full-file repair did not publish its result") { item.status == .completed }
        precondition(item.fullText == "完整录音")
    }

    private static func emptyFinalBackgroundNoiseDoesNotRepair() async throws {
        let (state, recorder, service) = makeSession("empty-noise-final")
        await service.configure(emptyChunk: 1)
        recorder.buffer.append(speech(10) + silent(0.5))
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial sealed speech was not published") {
            state.liveSegments.map(\.text) == ["词10"]
        }
        // Deliver another capture packet so the normal minimum-new-audio gate
        // permits the remaining silence to advance the audio cursor.
        recorder.buffer.append(silent(0.75))
        try await eventually("Sealed speech and following silence did not finish processing") {
            state.liveSegments.map(\.text) == ["词10"] && recorder.buffer.availableRange.lowerBound >= 36_000
        }
        // This is above the cheap RMS cutoff but has no decoded speech. There is
        // no provisional sentence to lose and no missing captured audio.
        recorder.appendOnStop = Array(repeating: Float(0.002), count: 3200)
        await state.finishRecording(recorder: recorder)
        precondition(state.items.count == 1 && state.items[0].status == .completed)
        precondition(state.items[0].fullText == "词10")
        let files = await service.fileCount()
        precondition(files == 0, "No-speech final background noise must not force full-file repair")
    }

    private static func transientEmptyPreservesDraftAndRecovers(overlapOnly: Bool) async throws {
        let (state, recorder, service) = makeSession(overlapOnly ? "recover-overlap" : "recover-empty")
        await service.configure(emptyChunk: overlapOnly ? nil : 1,
                                overlapOnlyChunk: overlapOnly ? 1 : nil)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial draft paragraph missing") { state.liveSegments.count == 13 }
        let draft = state.liveSegments
        // More than a complete inference window remains after the existing seal.
        // A single empty result must preserve the draft and wait for NEW capture,
        // rather than immediately retrying this full unchanged window forever.
        for marker in 14...42 { recorder.buffer.append(speech(marker)) }
        try await eventually("Injected empty/overlap-only result was not requested") {
            await service.chunkCount() >= 2
        }
        try await Task.sleep(for: .milliseconds(650))
        precondition(state.isLiveTranscribing && state.liveSegments == draft,
                     "A transient empty revision must not erase the displayed draft or terminate live ASR")
        let attemptsBeforeNewAudio = await service.chunkCount()
        precondition(attemptsBeforeNewAudio == 2, "Unchanged full-window audio caused a retry busy loop")
        recorder.buffer.append(speech(43))
        try await eventually("ASR did not recover when new capture arrived") {
            state.liveSegments.last?.text == "词43"
        }
        await state.finishRecording(recorder: recorder)
        let item = state.items[0]
        precondition(item.status == .completed)
        precondition(item.fullText == (1...43).map { "词\($0)" }.joined(),
                     "Recovered inference must preserve every word across the temporary empty result")
        let files = await service.fileCount()
        precondition(files == 0, "Transient empty output permanently tainted a successfully recovered session")
    }

    private static func recoverableAdmissionFailureDoesNotRepair(queuedTimeout: Bool) async throws {
        let (state, recorder, service) = makeSession(queuedTimeout ? "recover-queued-timeout" : "recover-busy")
        await service.configure(busyChunk: queuedTimeout ? nil : 1,
                                queuedTimeoutChunk: queuedTimeout ? 1 : nil)
        recorder.buffer.append(speech(10) + silent(0.5))
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial text before admission error missing") { !state.liveSegments.isEmpty }
        recorder.buffer.append(speech(20, seconds: 2))
        try await eventually("Transient queue rejection was not retried") {
            await service.chunkCount() >= 3 && state.liveSegments.last?.text == "词20"
        }
        precondition(state.isLiveTranscribing, "Backpressure must not terminate a recoverable recording")
        await state.finishRecording(recorder: recorder)
        precondition(state.items[0].status == .completed && state.items[0].fullText == "词10词20")
        let files = await service.fileCount()
        precondition(files == 0, "A queue wait timeout is not a lost-audio/inference timeout")
    }

    private static func persistentEmptyBacklogFinishesWithoutLooping() async throws {
        let (state, recorder, service) = makeSession("persistent-empty-finish")
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        await service.configure(emptyFromChunk: 1, decodeCallBudget: 6)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial persistent-empty test translation did not start") {
            await translation.count() == 1 && state.liveSegments.count == 13
        }
        await translation.complete(0, prefix: "RETAINED")
        try await eventually("Initial retained translation missing") {
            state.liveTranslatedSegments.contains { $0.hasPrefix("RETAINED") }
        }
        let draft = state.liveSegments
        let translated = state.liveTranslatedSegments
        recorder.buffer.append(Array(repeating: Float(0.002), count: 45 * 16000))
        try await eventually("Persistent-empty backlog did not get its first empty revision") {
            await service.chunkCount() == 2
        }
        try await Task.sleep(for: .milliseconds(250))
        precondition(state.isLiveTranscribing && state.liveSegments == draft)

        let started = ContinuousClock.now
        await state.finishRecording(recorder: recorder)
        precondition(started.duration(to: .now) < .seconds(1),
                     "Finish retried unchanged >30s empty backlog instead of filing it for repair")
        let chunkCount = await service.chunkCount()
        let budgetFailures = await service.decodeBudgetFailureCount()
        precondition(chunkCount <= 3 && budgetFailures == 0,
                     "No-progress Finish must exit after at most one additional decoder call")
        try await eventually("Persistent-empty Finish did not queue full-file repair") {
            await service.fileCount() == 1
        }
        let item = state.items[0]
        precondition(item.status != .completed && item.segments == draft)
        precondition(item.fullText.hasSuffix("词13") && item.translatedSegments == translated
                     && item.translationLanguage == "en",
                     "Persistent-empty Finish lost the unsealed final sentence or its completed translations")
        precondition(TranscriptionStore.saves.contains {
            $0.id == item.id && $0.status == .pending && $0.text == draft.map(\.text).joined()
                && $0.translations == translated && $0.translationLanguage == "en"
        })
        precondition(recorder.bufferClears == 1 && !state.isFinishingRecording)
        await service.failFile()
        try await eventually("Fixture repair was not released after persistent-empty Finish") {
            if case .failed = item.status { return true }
            return false
        }
        precondition(item.segments == draft && item.translatedSegments == translated)
        await translation.completeAll()
    }

    private static func persistentEmptyLiveDegradesBeforeBufferEviction() async throws {
        let (state, recorder, service) = makeSession("persistent-empty-live")
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        await service.configure(emptyFromChunk: 1, decodeCallBudget: 6)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial live-degradation translation did not start") {
            await translation.count() == 1 && state.liveSegments.count == 13
        }
        await translation.complete(0, prefix: "RETAINED")
        try await eventually("Live-degradation translation was not published") {
            state.liveTranslatedSegments.contains { $0.hasPrefix("RETAINED") }
        }
        let draft = state.liveSegments
        let translated = state.liveTranslatedSegments
        recorder.buffer.append(Array(repeating: Float(0.002), count: 16000))
        try await eventually("First no-progress live revision missing") { await service.chunkCount() == 2 }
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.isLiveTranscribing && state.liveSegments == draft)

        recorder.buffer.append(Array(repeating: Float(0.002), count: 5 * 16000))
        try await eventually("A retry within the recovery allowance was not attempted") {
            await service.chunkCount() == 3
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.isLiveTranscribing && state.liveSegments == draft,
                     "A second empty result must still allow recovery before the 12s new-audio budget")

        recorder.buffer.append(Array(repeating: Float(0.002), count: 7 * 16000))
        try await eventually("Persistent empty inference did not degrade after 12s of additional capture") {
            !state.isLiveTranscribing && state.liveError != nil
        }
        let chunkCount = await service.chunkCount()
        let budgetFailures = await service.decodeBudgetFailureCount()
        precondition(chunkCount == 4 && budgetFailures == 0)
        precondition(state.liveSegments == draft && state.liveTranslatedSegments == translated)
        precondition(recorder.state == .recording && recorder.stopCalls == 0
                     && recorder.accumulatedSampleCount < 90 * 16000,
                     "Inference must stop safely while durable recording continues, before PCM cap eviction")
        precondition(state.liveError?.localizedCaseInsensitiveContains("saved") == true,
                     "No-progress degradation must explain the saved-audio repair path")
        recorder.buffer.append(Array(repeating: Float(0.002), count: 16000))
        try await Task.sleep(for: .milliseconds(350))
        let afterMoreCapture = await service.chunkCount()
        precondition(afterMoreCapture == chunkCount, "Degraded live worker kept retrying empty audio")

        await state.finishRecording(recorder: recorder)
        try await eventually("Degraded live state did not persist into full-file repair at Finish") {
            await service.fileCount() == 1
        }
        let item = state.items[0]
        precondition(item.status != .completed && item.segments == draft
                     && item.translatedSegments == translated && item.translationLanguage == "en")
        await service.failFile()
        try await eventually("Fixture repair was not released after live degradation") {
            if case .failed = item.status { return true }
            return false
        }
        await translation.completeAll()
    }

    private enum FileRepairOutcome: String, CaseIterable { case failed, sameSource, changedSource }

    private struct RecoveryFixture: Decodable {
        let segments: [TranscriptionSegment]
        let translatedSegments: [String]
        let translationLanguage: String?
    }

    private static func retainedDraftSurvivesBufferEviction(lateTranslation: Bool) async throws {
        let name = lateTranslation ? "retained-cap-late-translation" : "retained-cap"
        let (state, recorder, service) = makeSession(name)
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        await service.configure(emptyFromChunk: 1, decodeCallBudget: 4)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Cap fixture initial translation did not start") {
            await translation.count() == 1 && state.liveSegments.count == 13
        }
        if !lateTranslation {
            await translation.complete(0, prefix: "BEFORECAP")
            try await eventually("Pre-cap translation was not published") {
                state.liveTranslatedSegments.contains { $0.hasPrefix("BEFORECAP") }
            }
        }
        let draft = state.liveSegments
        let translationsBeforeCap = state.liveTranslatedSegments
        recorder.buffer.append(Array(repeating: Float(0.002), count: 16000))
        try await eventually("Cap fixture first retained-empty revision missing") { await service.chunkCount() == 2 }
        try await Task.sleep(for: .milliseconds(100))
        recorder.buffer.append(Array(repeating: Float(0.002), count: 100 * 16000))
        precondition(recorder.buffer.availableRange.lowerBound > 12 * 16000,
                     "Fixture must actually evict the PCM underlying the retained draft")
        try await eventually("PCM eviction failed to stop a retained-draft live worker") {
            !state.isLiveTranscribing && state.liveError != nil
        }
        let chunks = await service.chunkCount()
        let budgetFailures = await service.decodeBudgetFailureCount()
        precondition(chunks == 2 && budgetFailures == 0,
                     "The cap path must preserve the old draft without another decode or retry loop")
        precondition(state.liveSegments == draft && state.liveTranslatedSegments == translationsBeforeCap)
        precondition(recorder.state == .recording && recorder.stopCalls == 0)
        let recoveryURL = directory.appendingPathComponent(name + ".json")
        try await eventually("Terminal cap transition did not checkpoint its retained draft") {
            guard let data = try? Data(contentsOf: recoveryURL),
                  let recovery = try? JSONDecoder().decode(RecoveryFixture.self, from: data) else { return false }
            return recovery.segments == draft && recovery.translatedSegments == translationsBeforeCap
        }
        if lateTranslation {
            // The periodic live loop is already stopped. A later network result
            // must flush its revision through the translation worker's terminal path.
            await translation.complete(0, prefix: "AFTERCAP")
            try await eventually("Late translation was not published after live inference stopped") {
                state.liveTranslatedSegments.contains { $0.hasPrefix("AFTERCAP") }
            }
            let lateTranslations = state.liveTranslatedSegments
            try await eventually("Late translation was missing from the stopped-loop recovery checkpoint") {
                guard let data = try? Data(contentsOf: recoveryURL),
                      let recovery = try? JSONDecoder().decode(RecoveryFixture.self, from: data) else { return false }
                return recovery.segments == draft && recovery.translatedSegments == lateTranslations
                    && recovery.translationLanguage == "en"
            }
        }
        let finalTranslations = state.liveTranslatedSegments
        await state.finishRecording(recorder: recorder)
        try await eventually("Cap-repair state did not enqueue the durable audio at Finish") {
            await service.fileCount() == 1
        }
        let item = state.items[0]
        precondition(item.status != .completed && item.segments == draft
                     && item.translatedSegments == finalTranslations && item.translationLanguage == "en")
        await service.failFile()
        try await eventually("Cap fixture full-file request was not released") {
            if case .failed = item.status { return true }
            return false
        }
        await translation.completeAll()
    }

    private static func successfulRevisionResetsEmptyRecoveryBudget() async throws {
        let (state, recorder, service) = makeSession("empty-recovery-budget-reset")
        await service.configure(emptyChunk: 1, decodeCallBudget: 8, additionalEmptyChunks: [3])
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Budget-reset initial draft missing") { state.liveSegments.count == 13 }
        recorder.buffer.append(speech(14))
        try await eventually("Budget-reset first empty revision missing") { await service.chunkCount() == 2 }
        try await Task.sleep(for: .milliseconds(100))
        recorder.buffer.append(speech(15))
        try await eventually("Intermediate successful recognition did not recover") {
            state.liveSegments.last?.text == "词15"
        }
        let recoveredDraft = state.liveSegments

        // This new empty result is more than 12 captured seconds after the FIRST
        // empty result, but successful recognition in between resets that budget.
        for marker in 16...28 { recorder.buffer.append(speech(marker)) }
        try await eventually("Second independent empty revision missing") { await service.chunkCount() == 4 }
        try await Task.sleep(for: .milliseconds(250))
        precondition(state.isLiveTranscribing && state.liveSegments == recoveredDraft,
                     "A completed recovery must reset the no-progress budget for a later transient empty result")
        recorder.buffer.append(speech(29))
        try await eventually("Recognition did not recover from the second independent empty result") {
            state.liveSegments.last?.text == "词29"
        }
        await state.finishRecording(recorder: recorder)
        let item = state.items[0]
        precondition(item.status == .completed && item.fullText == (1...29).map { "词\($0)" }.joined())
        let fileCount = await service.fileCount()
        let budgetFailures = await service.decodeBudgetFailureCount()
        precondition(fileCount == 0 && budgetFailures == 0)
    }

    private static func fullFileRepairPreservesTranslation(outcome: FileRepairOutcome) async throws {
        let (state, recorder, service) = makeSession("repair-translation-" + outcome.rawValue)
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        await service.configure(failChunk: 1)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Sealed speech was not submitted for translation") { await translation.count() == 1 }
        await translation.complete(0, prefix: "KEPT")
        try await eventually("Completed live translation missing") {
            state.liveTranslatedSegments.contains { $0.hasPrefix("KEPT") }
        }
        let expectedTranslations = state.liveTranslatedSegments
        await state.finishRecording(recorder: recorder)
        try await eventually("Actual inference timeout did not queue file repair") { await service.fileCount() == 1 }
        let item = state.items[0]
        precondition(item.status != .completed && item.translatedSegments == expectedTranslations,
                     "Pending file repair must retain already-paid-for live translations")
        precondition(item.translationLanguage == "en", "Pending repair lost the translation language")
        precondition(TranscriptionStore.saves.contains {
            $0.id == item.id && $0.status == .pending
                && $0.translations == expectedTranslations && $0.translationLanguage == "en"
        }, "The first durable pending-item save must contain its retained translations")
        let source = item.segments
        switch outcome {
        case .failed:
            await service.failFile()
            try await eventually("Injected file repair failure not published") {
                if case .failed = item.status { return true }
                return false
            }
            precondition(item.segments == source && item.translatedSegments == expectedTranslations)
            precondition(item.translationLanguage == "en", "Failed repair must keep its recoverable bilingual draft")
        case .sameSource:
            // Changed ASR timestamps alone do not invalidate a text-aligned translation.
            let retimed = source.map {
                TranscriptionSegment(start: $0.start + 0.01, end: $0.end.map { $0 + 0.01 }, text: $0.text)
            }
            await service.releaseFile(result: TranscriptionResult(text: retimed.map(\.text).joined(), segments: retimed))
            try await eventually("Matching-source file repair did not complete") { item.status == .completed }
            precondition(item.translatedSegments == expectedTranslations && item.translationLanguage == "en",
                         "Matching source text must retain translations after timestamp correction")
        case .changedSource:
            await service.releaseFile()
            try await eventually("Changed-source file repair did not complete") { item.status == .completed }
            precondition(item.translatedSegments.isEmpty && item.translationLanguage == nil,
                         "Changed source paragraphs must not display misaligned stale translations")
            precondition(state.transientToast?.localizedCaseInsensitiveContains("translation") == true,
                         "Invalidated translations need a visible explanation")
        }
        await translation.completeAll()
    }

    private static func cancelledFinishDoesNotSpinInTranslationGrace() async throws {
        let (state, recorder, service) = makeSession("cancelled-finish-grace")
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        recorder.buffer.append(speech(10) + silent(0.5))
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Held translation did not start") { await translation.count() == 1 }
        let finish = Task { await state.finishRecording(recorder: recorder) }
        try await eventually("Finish did not reach the translation-only grace period") {
            state.isFinishingRecording && !state.isLiveTranscribing && recorder.stopCalls == 1
        }
        let start = ContinuousClock.now
        finish.cancel()
        await finish.value
        precondition(start.duration(to: .now) < .seconds(1),
                     "Cancelled Task.sleep must not hot-loop through the 3-second translation grace")
        precondition(!state.isFinishingRecording && recorder.bufferClears == 1)
        let files = await service.fileCount()
        precondition(files == 0)
        await translation.completeAll()
    }

    private static func pausedTranslationCannotPublishIntoReplacement() async throws {
        let (state, recorder, service) = makeSession("translation-epoch")
        let translation = StubEnvironment.translation
        state.enableLiveTranslation = true
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial translation did not start") { await translation.count() == 1 }
        state.setLiveTranslationPaused(true)
        state.setLiveTranslationPaused(false)
        for marker in 14...26 { recorder.buffer.append(speech(marker)) }
        try await eventually("Replacement translation worker did not start") { await translation.count() == 2 }
        let resumedTexts = await translation.request(1)
        precondition(!resumedTexts.isEmpty && resumedTexts.first == "词14",
                     "Speech captured before resume must stay skipped")
        await translation.complete(0, prefix: "STALE")
        for _ in 0..<10 { await Task.yield() }
        precondition(!state.liveTranslatedSegments.contains { $0.hasPrefix("STALE") })

        let previousChunks = await service.chunkCount()
        for marker in 27...39 { recorder.buffer.append(speech(marker)) }
        try await eventually("ASR did not advance while translation was pending") {
            await service.chunkCount() > previousChunks && state.liveSegments.last?.end == 39
        }
        let pendingRequests = await translation.count()
        precondition(pendingRequests == 2,
                     "Old worker cleared the replacement handle, allowing a duplicate worker")
        await translation.complete(1, prefix: "OK")
        try await eventually("Current worker failed to publish") {
            state.liveTranslatedSegments.contains { $0.hasPrefix("OK") }
        }
        precondition(!state.liveTranslatedSegments.contains { $0.hasPrefix("STALE") })
        state.stopLiveTranscription()
        await translation.completeAll()
        for _ in 0..<10 { await Task.yield() }
        precondition(state.liveTranslatedSegments.isEmpty,
                     "A retired worker repopulated a reset recording")
    }

    private static func emptyFinalPreservesDraft(overlapOnly: Bool) async throws {
        let (state, recorder, service) = makeSession(overlapOnly ? "overlap-final" : "empty-final")
        await service.configure(emptyChunk: overlapOnly ? nil : 1,
                                overlapOnlyChunk: overlapOnly ? 1 : nil)
        for marker in 1...13 { recorder.buffer.append(speech(marker)) }
        state.startLiveTranscription(recorder: recorder)
        try await eventually("Initial sealed prefix and provisional tail missing") {
            state.liveSegments.count == 13
        }
        let draft = state.liveSegments.map(\.text).joined()
        await state.finishRecording(recorder: recorder)
        try await eventually("Empty final output was incorrectly accepted as complete") {
            await service.fileCount() == 1
        }
        let item = state.items[0]
        precondition(item.status != .completed && item.fullText == draft && item.fullText.hasSuffix("词13"),
                     "A failed final pass must retain the unsealed final sentence while awaiting repair")
        await service.releaseFile()
        try await eventually("Empty-final full-file repair did not complete") { item.status == .completed }
        precondition(item.fullText == "完整录音")
    }
}
