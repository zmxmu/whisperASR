import Foundation
import CWhisper
import os

final class TranscriptionService: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    private let processExitRequested = OSAllocatedUnfairLock(initialState: false)
    private let fileRequestsInFlight = OSAllocatedUnfairLock(initialState: 0)
    /// Serial queue to ensure only one whisper_full() runs at a time (ctx is not thread-safe).
    private let whisperQueue = CancellableTranscriptionQueue(label: "com.whisperasr.whisper")

    deinit {
        // A running worker retains self. Outside process termination, deinit can
        // therefore only release ctx after the last physical C operation returns.
        if !processExitRequested.withLock({ $0 }), let ctx { whisper_free(ctx) }
    }

    func shutdown() {
        // Termination only: do not block the main thread on an unresponsive GPU,
        // and do not enqueue a free that could race process/Metal teardown. Leave
        // the context alive for process reclamation; this is NOT a model-unload API.
        processExitRequested.withLock { $0 = true }
        whisperQueue.shutdown()
    }

    /// Transcribe (or translate-to-English, when `translate` is true) an audio file.
    /// `language` is an optional ISO-639-1 code; nil/empty means auto-detect.
    func transcribe(fileURL: URL,
                    language: String? = nil,
                    translate: Bool = false,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        // Bound decoded-file retention too: admission checks alone would let many
        // concurrent HTTP requests all start loading PCM before any one queues.
        let admitted = fileRequestsInFlight.withLock { count -> Bool in
            guard count < 2 else { return false }
            count += 1
            return true
        }
        guard admitted else { throw TranscriptionExecutionError.busy }
        defer { fileRequestsInFlight.withLock { $0 -= 1 } }
        try whisperQueue.checkAvailability()
        let samples = try await AudioLoader.loadSamples(url: fileURL)
        try Task.checkCancellation()
        return try await whisperQueue.perform(timeoutSeconds: max(60, Double(samples.count) / 16000 * 4)) { cancellation in
            try self.runTranscription(samples: samples, language: language,
                                      translate: translate, threadCount: nil,
                                      cancellation: cancellation, onProgress: onProgress)
        }
    }

    // MARK: - Chunk Transcription (Live/Streaming)

    /// Transcribe raw 16kHz mono PCM Float32 samples directly (used for live transcription during recording).
    /// This reuses the already-loaded whisper model and runs on a background queue.
    func transcribeChunk(samples: [Float], language: String? = nil,
                         timeoutSeconds: TimeInterval? = nil) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        let timeout = timeoutSeconds ?? max(60, Double(samples.count) / 16000 * 4)
        return try await whisperQueue.perform(timeoutSeconds: timeout) { cancellation in
            let liveThreads = min(4, max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 4)))
            return try self.runTranscription(samples: samples, language: language,
                                            translate: false, threadCount: liveThreads,
                                            cancellation: cancellation, onProgress: nil)
        }
    }

    /// Ensure the whisper model is loaded (public access for pre-loading during recording start).
    /// Cancellation/timeout resumes the caller even if model loading cannot be interrupted.
    /// The model operation still owns the serial slot until its C call really returns.
    func preloadModel() async throws {
        try await whisperQueue.perform(timeoutSeconds: 60) { cancellation in
            try cancellation.checkCancellation()
            _ = try self.ensureModelLoaded()
            try cancellation.checkCancellation()
        }
    }

    private func runTranscription(samples: [Float], language: String?, translate: Bool,
                                  threadCount: Int32?, cancellation: TranscriptionCancellation,
                                  onProgress: (@Sendable (Double) -> Void)?) throws -> TranscriptionResult {
        try cancellation.checkCancellation()
        let ctx = try ensureModelLoaded()
        try cancellation.checkCancellation()
        try validateLanguage(language, for: ctx)

        var (params, langCStr) = makeBaseParams(threadCount: threadCount,
                                              language: language, translate: translate)
        defer { free(langCStr) }
        // The retained box, samples, params and self live until whisper_full returns,
        // even when Swift has already resumed the caller with cancellation/timeout.
        let callbackBox = InferenceCallbackBox(cancellation: cancellation, progress: onProgress)
        let callbackPtr = Unmanaged.passRetained(callbackBox).toOpaque()
        defer { Unmanaged<InferenceCallbackBox>.fromOpaque(callbackPtr).release() }
        params.abort_callback_user_data = callbackPtr
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<InferenceCallbackBox>.fromOpaque(userData)
                .takeUnretainedValue().cancellation.isCancelled
        }
        if onProgress != nil {
            params.progress_callback_user_data = callbackPtr
            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let box = Unmanaged<InferenceCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                guard !box.cancellation.isCancelled else { return }
                DispatchQueue.main.async {
                    guard !box.cancellation.isCancelled else { return }
                    box.progress?(Double(progress) / 100)
                }
            }
        }

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        try cancellation.checkCancellation()
        guard result == 0 else {
            throw TranscriptionError.processFailed("whisper_full returned error \(result)")
        }

        let detected = detectedLanguage(in: ctx)
        var segments: [TranscriptionSegment] = []
        var fullText = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            try cancellation.checkCancellation()
            let t0 = whisper_full_get_segment_t0(ctx, i)
            let t1 = whisper_full_get_segment_t1(ctx, i)
            let text = whisper_full_get_segment_text(ctx, i).map {
                normalizedScript(String(cString: $0), language: detected, translate: translate)
            } ?? ""
            segments.append(TranscriptionSegment(start: Double(t0) / 100,
                                                  end: Double(t1) / 100, text: text))
            fullText += text
        }
        return TranscriptionResult(text: fullText, segments: segments, detectedLanguage: detected)
    }

    // MARK: - Params Configuration

    private func validateLanguage(_ language: String?, for ctx: OpaquePointer) throws {
        guard let language,
              !language.isEmpty,
              language != "auto",
              language != "en",
              whisper_is_multilingual(ctx) == 0 else { return }
        throw TranscriptionError.processFailed(
            "The selected model is English-only. Choose English or select a multilingual model."
        )
    }

    private func detectedLanguage(in ctx: OpaquePointer) -> String? {
        let langId = whisper_full_lang_id(ctx)
        guard langId >= 0, let langPtr = whisper_lang_str(langId) else { return nil }
        return String(cString: langPtr)
    }

    /// Normalize Chinese transcription to Simplified Chinese using ICU's
    /// built-in script conversion. No character dictionary is maintained here.
    private func normalizedScript(_ text: String,
                                  language: String?,
                                  translate: Bool = false) -> String {
        guard !translate, language == "zh" else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }

    /// Create base whisper params. `language` nil/empty means auto-detect; when
    /// `translate` is true whisper translates the audio to English.
    /// Caller must free the returned C string pointer after whisper_full completes.
    private func makeBaseParams(threadCount: Int32? = nil,
                                language: String? = nil,
                                translate: Bool = false) -> (whisper_full_params, UnsafeMutablePointer<CChar>?) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        // Suppress the model's built-in non-speech tokens (music, noise, etc.)
        // during decoding. This operates on token IDs, so it avoids maintaining
        // a language-dependent list of strings such as "[Music]".
        params.suppress_nst = true
        params.n_threads = threadCount ?? max(1, Int32(ProcessInfo.processInfo.activeProcessorCount / 2))
        params.translate = translate

        let lang = (language?.isEmpty == false) ? language! : "auto"
        let langCStr = strdup(lang)
        params.language = UnsafePointer(langCStr)

        return (params, langCStr)
    }

    /// Returns all languages supported by the loaded whisper.cpp library.
    static func availableLanguages() -> [(code: String, name: String)] {
        var langs: [(code: String, name: String)] = []
        let maxId = Int(whisper_lang_max_id())
        for i in 0...maxId {
            if let codePtr = whisper_lang_str(Int32(i)),
               let namePtr = whisper_lang_str_full(Int32(i)) {
                langs.append((code: String(cString: codePtr), name: String(cString: namePtr)))
            }
        }
        return langs
    }

    // MARK: - Model Management

    static var appSupportModelPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models/ggml-model.bin").path
    }

    /// Check whether a usable model file exists at any known location.
    static func modelExists() -> Bool {
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path),
           files.contains(where: { $0.hasSuffix(".bin") }) {
            return true
        }
        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return true
        }
        if FileManager.default.fileExists(atPath: appSupportModelPath) {
            return true
        }
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        let projectRoot = (sourcesDir as NSString).deletingLastPathComponent
        let projectPath = (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
        return FileManager.default.fileExists(atPath: projectPath)
    }

    /// Load (or re-load, when the resolved path changed) the model and return the context.
    /// MUST run on `whisperQueue`: reloading frees the previous context, which would
    /// crash a whisper_full running concurrently on the queue if done anywhere else.
    @discardableResult
    private func ensureModelLoaded() throws -> OpaquePointer {
        whisperQueue.assertOnQueue()
        let path = resolveModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.modelNotFound(
                "Model not found at: \(path)\n\n" +
                "Download a model in Settings → Speech Recognition Models."
            )
        }
        if loadedModelPath != path {
            if let ctx { whisper_free(ctx) }
            ctx = nil
            loadedModelPath = nil

            var cparams = whisper_context_default_params()
            cparams.use_gpu = true  // Metal GPU acceleration
            cparams.flash_attn = true

            ctx = path.withCString { whisper_init_from_file_with_params($0, cparams) }
            guard ctx != nil else {
                throw TranscriptionError.processFailed("Failed to load whisper model from: \(path)")
            }
            loadedModelPath = path
        }
        guard let ctx else {
            throw TranscriptionError.processFailed("Model not loaded")
        }
        return ctx
    }

    private func resolveModelPath() -> String {
        // Explicitly selected downloaded model (set via Settings or the toolbar picker)
        if let selected = UserDefaults.standard.string(forKey: "selectedModelFile"),
           !selected.isEmpty {
            let selectedPath = ModelCatalog.modelDirectory.appendingPathComponent(selected).path
            if FileManager.default.fileExists(atPath: selectedPath) {
                return selectedPath
            }
        }

        if let custom = UserDefaults.standard.string(forKey: "modelPath"),
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        // Check App Support path (where auto-download saves the model)
        let appSupportPath = Self.appSupportModelPath
        if FileManager.default.fileExists(atPath: appSupportPath) {
            return appSupportPath
        }

        // Fallback to project-relative path (development)
        let projectRoot = resolveProjectRoot()
        return (projectRoot as NSString).appendingPathComponent("Models/ggml-model.bin")
    }

    private func resolveProjectRoot() -> String {
        let thisFile = #filePath
        let sourcesDir = (thisFile as NSString).deletingLastPathComponent
        return (sourcesDir as NSString).deletingLastPathComponent
    }
}

// Shared callback state is retained until the C operation actually returns.
private final class InferenceCallbackBox: @unchecked Sendable {
    let cancellation: TranscriptionCancellation
    let progress: (@Sendable (Double) -> Void)?
    init(cancellation: TranscriptionCancellation, progress: (@Sendable (Double) -> Void)?) {
        self.cancellation = cancellation
        self.progress = progress
    }
}
