import Foundation
import Observation
import SwiftUI

// MARK: - Recognition Language Mode

enum RecognitionLanguageMode: String, CaseIterable {
    static let defaultsKey = "recognitionLanguageMode"

    case automatic
    case mandarin
    case english
    case mandarinEnglish

    var label: String {
        switch self {
        case .automatic: return "自动检测"
        case .mandarin: return "普通话"
        case .english: return "English"
        case .mandarinEnglish: return "中英混合"
        }
    }

    var helpText: String {
        switch self {
        case .automatic:
            return "Automatically detect any language supported by the selected model."
        case .mandarin:
            return "Treat the audio as Mandarin and output Simplified Chinese."
        case .english:
            return "Treat the audio as English."
        case .mandarinEnglish:
            return "Treat Mandarin as the primary language while preserving spoken English words."
        }
    }

    /// Whisper accepts one primary language token per decode window. A
    /// multilingual model can still emit English tokens while conditioned on
    /// Chinese, which is the most reliable setup for Mandarin-English speech
    /// without reopening auto-detection to every supported language.
    var whisperLanguage: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en"
        case .mandarin, .mandarinEnglish: return "zh"
        }
    }

    static var current: RecognitionLanguageMode {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        return raw.flatMap(RecognitionLanguageMode.init(rawValue:)) ?? .mandarinEnglish
    }
}

// MARK: - Transcript Font Size

enum TranscriptFontSize: String, CaseIterable {
    case small, normal, large

    var label: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Normal"
        case .large: return "Large"
        }
    }

    var bodyFont: Font {
        switch self {
        case .small: return .caption
        case .normal: return .body
        case .large: return .title3
        }
    }

    var translationFont: Font {
        switch self {
        case .small: return .caption2
        case .normal: return .callout
        case .large: return .body
        }
    }

    var timestampFont: Font {
        switch self {
        case .small: return .system(.caption2, design: .monospaced)
        case .normal: return .system(.caption, design: .monospaced)
        case .large: return .system(.footnote, design: .monospaced)
        }
    }
}

// MARK: - Transcription Segment

struct TranscriptionSegment: Codable, Equatable {
    let start: Double
    let end: Double?
    let text: String
}

// MARK: - Transcription Result

struct TranscriptionResult: Codable {
    let text: String
    let segments: [TranscriptionSegment]
    /// Whisper's auto-detected language code (e.g. "en", "zh"). Populated for
    /// file transcription; used by the OpenAI-compatible API's verbose_json.
    var detectedLanguage: String? = nil
}

// MARK: - Status

enum TranscriptionStatus: Equatable {
    case pending
    case transcribing
    case completed
    case failed(String)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Transcription failed: \(msg)"
        case .modelNotFound(let msg): return msg
        }
    }
}

// MARK: - Transcription Item

@Observable
class TranscriptionItem: Identifiable {
    let id: UUID
    var fileName: String
    var fileURL: URL
    var status: TranscriptionStatus = .pending
    var segments: [TranscriptionSegment] = []
    var fullText: String = ""
    var progress: Double = 0
    var transcriptionStartTime: Date?
    var translatedSegments: [String] = []
    var translationLanguage: String?
    var isTranslating: Bool = false
    let dateAdded: Date

    init(fileURL: URL) {
        self.id = UUID()
        self.fileName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.dateAdded = Date()
    }

    /// Restore from persisted data
    init(id: UUID, fileName: String, fileURL: URL, dateAdded: Date,
         status: TranscriptionStatus, segments: [TranscriptionSegment], fullText: String,
         translatedSegments: [String] = [], translationLanguage: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.dateAdded = dateAdded
        self.status = status
        self.segments = segments
        self.fullText = fullText
        self.translatedSegments = translatedSegments
        self.translationLanguage = translationLanguage
    }
}
