// Standalone AppKit regression/performance checks (no microphone or model required).
// swiftc -O Sources/Models.swift Sources/LiveTranscriptTextView.swift Tests/LiveTranscriptChecks.swift -o .build/live-transcript-checks
// .build/live-transcript-checks
import AppKit
import SwiftUI

@main
struct LiveTranscriptChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var segments = (0..<3600).map {
            TranscriptionSegment(start: Double($0), end: Double($0 + 1),
                                 text: "第\($0)句 English 中文 👩🏽‍💻。")
        }
        var translations: [String] = []
        var revision: UInt64 = 0
        let coordinator = LiveTranscriptTextView.Coordinator()
        func snapshot(only: Bool = false, size: TranscriptFontSize = .normal) -> LiveTranscriptTextView {
            LiveTranscriptTextView(segments: segments, translations: translations,
                                   revision: revision, fontSize: size, translationOnly: only)
        }
        let scroll = snapshot().makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let text = coordinator.textView!
        func refresh(only: Bool = false, size: TranscriptFontSize = .normal) {
            revision += 1
            coordinator.pending = snapshot(only: only, size: size)
            coordinator.renderPending()
        }
        refresh()
        precondition(!text.isEditable && text.isSelectable)
        let original = text.string
        precondition(original == segments.map { $0.text + "\n" }.joined())

        // A continuous selection spans Unicode and multiple paragraphs inside the stable
        // history. New recognition appended after it must keep flowing, and the selection
        // (range and text) must survive the tail edit untouched.
        let selection = NSRange(location: 0, length: (segments[0].text + "\n" + segments[1].text).utf16.count)
        text.setSelectedRange(selection)
        let selectedText = (text.string as NSString).substring(with: selection)
        segments.append(TranscriptionSegment(start: 3600, end: 3601, text: "新增 tail"))
        refresh()
        precondition(text.string.hasSuffix("新增 tail\n"), "Tail must keep updating while history is selected")
        precondition(text.selectedRange() == selection)
        precondition((text.string as NSString).substring(with: selection) == selectedText)

        // A translation for a selected segment would rewrite the selected text itself:
        // that update waits until the selection is cleared, then catches up.
        let frozenHistory = text.string
        translations = ["Translated first sentence"]
        refresh()
        precondition(text.string == frozenHistory && text.selectedRange() == selection)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.renderPending()
        precondition(text.string.contains("Translated first sentence\n"))
        precondition(text.string.hasSuffix("新增 tail\n"))
        precondition(text.string.hasPrefix(segments[0].text + "\nTranslated first sentence\n" + segments[1].text + "\n"))

        // A selection reaching into the live tail freezes the document until it is cleared.
        let tailLocation = (text.string as NSString).range(of: "新增 tail").location
        // Start on "。\n" so the range does not split the preceding emoji cluster.
        let tailSelection = NSRange(location: tailLocation - 2, length: 6)
        text.setSelectedRange(tailSelection)
        precondition(text.selectedRange() == tailSelection)
        let frozenTail = text.string
        segments[segments.count - 1] = TranscriptionSegment(start: 3600, end: 3601, text: "changed tail")
        refresh()
        precondition(text.string == frozenTail && text.selectedRange() == tailSelection)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.renderPending()
        precondition(text.string.hasSuffix("changed tail\n"))
        precondition(!text.string.contains("新增 tail"))

        // A collapsed caret inside the tail is pulled back to the tail start, never left dangling.
        text.setSelectedRange(NSRange(location: text.string.utf16.count - 2, length: 0))
        segments[segments.count - 1] = TranscriptionSegment(start: 3600, end: 3601, text: "x")
        refresh()
        precondition(text.selectedRange().length == 0 && text.selectedRange().location <= text.string.utf16.count)
        precondition(text.string.hasSuffix("x\n"))

        // Tail revisions should only edit the suffix, even with an hour's history.
        let editProbe = EditProbe()
        text.textStorage!.delegate = editProbe
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<100 {
                segments[segments.count - 1] = TranscriptionSegment(start: 3600, end: 3601, text: "revised \(i) 👋")
                refresh()
            }
        }
        precondition(editProbe.maximumEditedLength < 100, "Historical text was replaced")
        precondition(text.string.hasSuffix("revised 99 👋\n"))

        // Reading old text must not snap back to the newest sentence.
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let readingOrigin = scroll.contentView.bounds.origin
        segments[segments.count - 1] = TranscriptionSegment(start: 3600, end: 3601, text: "longer tail\nsecond line")
        refresh()
        precondition(abs(scroll.contentView.bounds.origin.y - readingOrigin.y) < 1)
        text.isSelecting = true
        let duringDrag = text.string
        segments.append(TranscriptionSegment(start: 3601, end: 3602, text: "during drag"))
        refresh()
        precondition(text.string == duringDrag)
        text.isSelecting = false
        coordinator.renderPending()
        precondition(text.string.hasSuffix("during drag\n"))

        // Same last translation, different earlier translation must still update.
        translations = ["first", "last"]
        refresh()
        translations[0] = "changed first"
        refresh()
        precondition(text.string.contains("changed first\n"))
        refresh(only: true)
        precondition(text.string == "changed first\nlast\n")
        refresh(size: .large)
        precondition(text.string.contains(segments[0].text))
        segments = Array(segments.prefix(2))
        refresh()
        precondition(!text.string.contains("revised 99"))
        segments = []
        translations = []
        refresh()
        precondition(text.string.isEmpty)
        print("PASS: read-only, history selection survives tail updates, tail-overlapping selection freezes and catches up, drag freeze, scroll preservation, translations, style, truncation, empty document")
        print("PASS: 100 tail updates with 3,601 segments: \(elapsed); maximum edited range before full-replacement cases < 100 UTF-16 units")
    }

    final class EditProbe: NSObject, NSTextStorageDelegate {
        var maximumEditedLength = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            maximumEditedLength = max(maximumEditedLength, editedRange.length)
        }
    }
}
