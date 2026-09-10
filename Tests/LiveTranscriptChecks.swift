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
        checkInteractionBoundaries()
        checkMountedEmptySnapshot()
    }

    @MainActor private static func checkInteractionBoundaries() {
        var segments = [
            TranscriptionSegment(start: 1, end: 2, text: "历史 A 👩🏽‍💻"),
            TranscriptionSegment(start: 62, end: 63, text: "历史 B 中文 English"),
            TranscriptionSegment(start: 3663, end: 3664, text: "尾部 C")
        ]
        var translations = ["translation A", "translation B", "translation C"]
        var revision: UInt64 = 0
        var resumeRequest: UInt64 = 0
        var only = false
        var size = TranscriptFontSize.normal
        let coordinator = LiveTranscriptTextView.Coordinator()
        func snapshot(source: UInt64? = nil, dirty: Int? = nil) -> LiveTranscriptTextView {
            LiveTranscriptTextView(segments: segments, translations: translations,
                                   revision: revision, fontSize: size, translationOnly: only,
                                   sourceRevision: source, dirtyFrom: dirty, resumeRequest: resumeRequest)
        }
        let scroll = snapshot().makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        let text = coordinator.textView!
        func refresh(source: UInt64? = nil, dirty: Int? = nil) {
            revision &+= 1
            coordinator.pending = snapshot(source: source, dirty: dirty)
            coordinator.renderPending()
        }
        refresh()

        // An earlier translation and a tail append are disjoint edits. Preserve the
        // selected paragraph in between, including its shifted UTF-16 position.
        text.setSelectedRange((text.string as NSString).range(of: segments[1].text))
        let chosen = (text.string as NSString).substring(with: text.selectedRange())
        translations[0] = "A much longer translation 👋"
        segments.append(TranscriptionSegment(start: 3664, end: 3665, text: "new D"))
        refresh()
        precondition(!coordinator.isPaused && text.string.hasSuffix("new D\n"))
        precondition((text.string as NSString).substring(with: text.selectedRange()) == chosen)
        precondition(coordinator.copyText(.original) == segments[1].text)
        precondition(coordinator.copyText(.translation) == "translation B")
        precondition(coordinator.copyText(.timestamped) == "[00:01:02] 历史 B 中文 English\ntranslation B")

        // Font changes apply immediately without discarding a selection. Display-mode
        // changes are explicit user actions and intentionally clear it.
        let beforeFont = text.selectedRange()
        size = .large
        refresh()
        precondition(text.selectedRange() == beforeFont)
        precondition((text.textStorage!.attribute(.font, at: beforeFont.location, effectiveRange: nil) as? NSFont)?.pointSize == 15)
        only = true
        refresh()
        precondition(text.selectedRange().length == 0 && !coordinator.isPaused)
        precondition(text.string == translations.joined(separator: "\n") + "\n")
        only = false
        refresh()

        // A history selection at the bottom must stop following new text, even though
        // those new paragraphs can still be rendered without changing the selection.
        text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
        text.setSelectedRange((text.string as NSString).range(of: "尾部 C"))
        let readingOrigin = scroll.contentView.bounds.origin
        segments.append(TranscriptionSegment(start: 3665, end: 3666,
                                             text: String(repeating: "new paragraph\n", count: 10)))
        refresh()
        precondition(abs(scroll.contentView.bounds.origin.y - readingOrigin.y) < 1)
        precondition((text.string as NSString).substring(with: text.selectedRange()) == "尾部 C")

        // Cmd+A always freezes a snapshot, including pure append. Copy actions use
        // rendered source metadata, not the newest pending recognition.
        text.selectAll(nil)
        let frozen = text.string
        let frozenSource = coordinator.copyText(.original)
        segments[0] = TranscriptionSegment(start: 1, end: 2, text: "changed pending A")
        segments.append(TranscriptionSegment(start: 3666, end: 3667, text: "append while all selected"))
        refresh()
        precondition(coordinator.isPaused && text.string == frozen)
        precondition(coordinator.copyText(.original) == frozenSource)
        resumeRequest &+= 1
        refresh()
        precondition(!coordinator.isPaused && text.selectedRange().length == 0)
        precondition(text.string.hasSuffix("append while all selected\n"))
        text.selectAll(nil)
        segments.append(TranscriptionSegment(start: 3667, end: 3668, text: "pure append"))
        let beforeAppend = text.string
        refresh()
        precondition(coordinator.isPaused && text.string == beforeAppend)
        text.cancelOperation(nil)
        precondition(!coordinator.isPaused && text.string.hasSuffix("pure append\n"))

        // Empty provisional recognition must retain the selectable document until
        // deselection, then safely catch up to an empty storage and offset table.
        text.selectAll(nil)
        let beforeEmpty = text.string
        segments = []
        translations = []
        refresh()
        precondition(coordinator.isPaused && text.string == beforeEmpty)
        coordinator.resumeLive(nil)
        precondition(text.string.isEmpty && text.selectedRange() == NSRange(location: 0, length: 0))

        // A stale producer hint must not skip an earlier translation after a missed
        // revision. This also exercises offsets after deleting the whole document.
        segments = [TranscriptionSegment(start: 0, end: 1, text: "new session row")]
        translations = ["first version"]
        refresh()
        let staleRevision = revision - 1
        translations[0] = "changed earlier translation"
        refresh(source: staleRevision, dirty: 1)
        precondition(text.string.contains("changed earlier translation"))
        let currentRevision = revision
        segments.append(TranscriptionSegment(start: 1, end: 2, text: "hinted append"))
        refresh(source: currentRevision, dirty: 1)
        precondition(text.string.hasSuffix("hinted append\n"))

        let menu = NSMenu()
        coordinator.addTranscriptActions(to: menu)
        coordinator.addTranscriptActions(to: menu)
        precondition(menu.items.count == 5, "Reused context menus must not accumulate duplicate actions")
        precondition(menu.items.contains { $0.title == "Copy Selected Paragraphs — Original" })
        precondition(menu.items.contains { $0.title == "Copy Selected Paragraphs — Translation" })
        precondition(menu.items.contains { $0.title == "Copy Selected Paragraphs with Timestamps" })
        precondition(menu.items.contains { $0.title == "Resume Live Updates" })
        print("PASS: disjoint translation edits, frozen-source copy/timestamps, font/mode changes, selected-history scroll, Cmd+A pure-append pause, Resume/Escape, empty catch-up, revision hint fallback, context actions")
    }

    @MainActor private static func checkMountedEmptySnapshot() {
        // Exercise real NSViewRepresentable updates inside SwiftUI, not just direct
        // coordinator calls. The always-mounted document must survive an empty model.
        let first = LiveTranscriptTextView(
            segments: [TranscriptionSegment(start: 0, end: 1, text: "provisional first sentence")],
            translations: [], revision: 1, fontSize: .normal, translationOnly: false)
        let hosting = NSHostingView(rootView: first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        func findText(_ view: NSView) -> LiveTranscriptTextView.SelectionTextView? {
            if let text = view as? LiveTranscriptTextView.SelectionTextView { return text }
            return view.subviews.lazy.compactMap(findText).first
        }
        settle()
        let text = findText(hosting)!
        text.setSelectedRange(NSRange(location: 0, length: 11))
        hosting.rootView = LiveTranscriptTextView(segments: [], translations: [], revision: 2,
                                                  fontSize: .normal, translationOnly: false)
        settle()
        precondition(findText(hosting) === text)
        precondition(text.string == "provisional first sentence\n" && text.selectedRange().length > 0)
        text.cancelOperation(nil)
        settle()
        precondition(text.string.isEmpty && findText(hosting) === text)
        window.close()
        print("PASS: mounted SwiftUI document survives empty recognition while selected and clears after Resume")
    }

    final class EditProbe: NSObject, NSTextStorageDelegate {
        var maximumEditedLength = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            maximumEditedLength = max(maximumEditedLength, editedRange.length)
        }
    }
}
