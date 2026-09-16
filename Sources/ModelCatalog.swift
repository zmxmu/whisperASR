import Foundation
import Observation

// MARK: - Model Catalog

/// Inference engine a catalog model runs on.
enum ModelEngine: Equatable {
    /// whisper.cpp GGML model — a single .bin file.
    case whisper
    /// NVIDIA Nemotron streaming ASR via FluidAudio (Core ML / ANE) — a
    /// directory bundle (encoder/decoder/joint .mlmodelc + metadata + tokenizer).
    case nemotron
}

/// Where a catalog model's bytes come from.
enum DownloadSource: Equatable {
    /// Single file downloaded to Models/<fileName>.
    case file(URL)
    /// Every file under `folder` in a Hugging Face repo, downloaded into the
    /// Models/<fileName>/ directory (tree listed via the HF API at download time).
    case hfFolder(repo: String, folder: String)
}

/// A speech-recognition model available for in-app download.
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    /// On-disk name inside the Models directory: a file (whisper) or a directory (nemotron).
    let fileName: String
    let source: DownloadSource
    let approxBytes: Int64
    var engine: ModelEngine = .whisper

    var approxSizeText: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// All downloadable models. Breeze-ASR-25 is the default (best for
    /// Mandarin/Taiwanese); Nemotron is NVIDIA's multilingual streaming model
    /// running on the Neural Engine; the rest are official whisper.cpp conversions.
    static let all: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "breeze-asr-25",
            displayName: "Breeze-ASR-25",
            detail: "Best for Mandarin and Taiwanese-accented speech",
            fileName: "ggml-model.bin",
            source: .file(URL(string: "https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/resolve/main/ggml-model.bin")!),
            approxBytes: 3_100_000_000
        ),
        WhisperModelInfo(
            id: "nemotron-3.5-multilingual",
            displayName: "Nemotron 3.5 Multilingual",
            detail: "NVIDIA streaming ASR, ~40 languages with punctuation, Neural Engine",
            fileName: "nemotron-3.5-multilingual-2240ms",
            source: .hfFolder(
                repo: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
                folder: "multilingual/2240ms"
            ),
            approxBytes: 665_000_000,
            engine: .nemotron
        ),
        WhisperModelInfo(
            id: "large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            detail: "Near large-v3 quality, much faster",
            fileName: "ggml-large-v3-turbo.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!),
            approxBytes: 1_620_000_000
        ),
        WhisperModelInfo(
            id: "medium",
            displayName: "Whisper Medium",
            detail: "Good multilingual quality",
            fileName: "ggml-medium.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!),
            approxBytes: 1_530_000_000
        ),
        WhisperModelInfo(
            id: "small",
            displayName: "Whisper Small",
            detail: "Fast, decent quality",
            fileName: "ggml-small.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!),
            approxBytes: 488_000_000
        ),
        WhisperModelInfo(
            id: "base",
            displayName: "Whisper Base",
            detail: "Very fast, basic quality",
            fileName: "ggml-base.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!),
            approxBytes: 148_000_000
        ),
        WhisperModelInfo(
            id: "tiny",
            displayName: "Whisper Tiny",
            detail: "Fastest, lowest quality",
            fileName: "ggml-tiny.bin",
            source: .file(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!),
            approxBytes: 78_000_000
        ),
    ]

    static func model(id: String) -> WhisperModelInfo? {
        all.first { $0.id == id }
    }

    static func model(fileName: String) -> WhisperModelInfo? {
        all.first { $0.fileName == fileName }
    }

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models")
    }

    static func path(for model: WhisperModelInfo) -> URL {
        modelDirectory.appendingPathComponent(model.fileName)
    }

    /// Whether everything the model needs is on disk (a directory bundle can
    /// exist but be missing files after an interrupted download).
    static func isComplete(_ model: WhisperModelInfo) -> Bool {
        let base = path(for: model)
        switch model.engine {
        case .whisper:
            return FileManager.default.fileExists(atPath: base.path)
        case .nemotron:
            let required = [
                "metadata.json",
                "tokenizer.json",
                "encoder.mlmodelc/weights/weight.bin",
            ]
            return required.allSatisfy {
                FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
            }
        }
    }
}

// MARK: - Model Manager

/// Tracks which models are on disk, in-flight downloads, and the user's
/// model selection (persisted in UserDefaults as "selectedModelFile").
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var downloadedFileNames: Set<String> = []
    private var downloaders: [String: ModelDownloader] = [:]

    /// File name (in the Models directory) of the model used for transcription.
    /// Empty = automatic (custom path from Settings, else the default model).
    var selectedFileName: String {
        didSet { UserDefaults.standard.set(selectedFileName, forKey: "selectedModelFile") }
    }

    /// File name of the model used for live transcription during recording —
    /// usually a smaller, faster one than the main model. Empty = use the main
    /// transcription model.
    var liveFileName: String {
        didSet { UserDefaults.standard.set(liveFileName, forKey: "liveModelFile") }
    }

    private init() {
        selectedFileName = UserDefaults.standard.string(forKey: "selectedModelFile") ?? ""
        liveFileName = UserDefaults.standard.string(forKey: "liveModelFile") ?? ""
        refresh()
        for model in ModelCatalog.all {
            downloaders[model.id] = ModelDownloader(model: model) { [weak self] in
                self?.downloadFinished(model)
            }
        }
    }

    var downloadedModels: [WhisperModelInfo] {
        ModelCatalog.all.filter { downloadedFileNames.contains($0.fileName) }
    }

    var selectedModel: WhisperModelInfo? {
        guard !selectedFileName.isEmpty else { return nil }
        return ModelCatalog.model(fileName: selectedFileName)
    }

    var liveModel: WhisperModelInfo? {
        guard !liveFileName.isEmpty else { return nil }
        return ModelCatalog.model(fileName: liveFileName)
    }

    func isDownloaded(_ model: WhisperModelInfo) -> Bool {
        downloadedFileNames.contains(model.fileName)
    }

    func downloader(for model: WhisperModelInfo) -> ModelDownloader {
        downloaders[model.id]!
    }

    /// Re-scan the Models directory. Catalog directory bundles only count as
    /// downloaded when all their required files are present.
    func refresh() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: ModelCatalog.modelDirectory.path)) ?? []
        var names: Set<String> = []
        for name in entries {
            if let model = ModelCatalog.model(fileName: name) {
                if ModelCatalog.isComplete(model) { names.insert(name) }
            } else if !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        downloadedFileNames = names
        // Drop a selection whose file no longer exists (deleted externally)
        if !selectedFileName.isEmpty && !downloadedFileNames.contains(selectedFileName) {
            selectedFileName = ""
        }
        if !liveFileName.isEmpty && !downloadedFileNames.contains(liveFileName) {
            liveFileName = ""
        }
    }

    func delete(_ model: WhisperModelInfo) {
        try? FileManager.default.removeItem(at: ModelCatalog.path(for: model))
        try? FileManager.default.removeItem(at: ModelDownloader.stagingDirectory(for: model))
        refresh()
    }

    /// Called on the main queue when a download completes. The user explicitly
    /// chose this model, so switch transcription to it right away.
    private func downloadFinished(_ model: WhisperModelInfo) {
        refresh()
        selectedFileName = model.fileName
    }
}
