import SwiftUI
import AppKit

/// One selectable document. Disjoint paragraph edits preserve unaffected selections.
/// Selecting changing text or selecting all pauses presentation, never capture/inference.
struct LiveTranscriptTextView: NSViewRepresentable {
    let segments: [TranscriptionSegment]
    let translations: [String]
    let revision: UInt64
    let fontSize: TranscriptFontSize
    let translationOnly: Bool
    // Optional producer hint. Skipped revisions always fall back to exact comparisons.
    var sourceRevision: UInt64? = nil
    var dirtyFrom: Int? = nil
    var resumeRequest: UInt64 = 0
    var onPauseChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = SelectionTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = true
        // Read-only transcript: no spelling/substitution/data-detector passes over hours of text.
        text.enabledTextCheckingTypes = 0
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.delegate = coordinator
        text.transcriptCoordinator = coordinator
        scroll.documentView = text
        coordinator.textView = text
        text.selectionInteractionEnded = { [weak coordinator] in
            coordinator?.renderPending()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.pending = self
        context.coordinator.renderPending()
    }

    final class SelectionTextView: NSTextView {
        var isSelecting = false
        var explicitlyPaused = false
        weak var transcriptCoordinator: Coordinator?
        var selectionInteractionEnded: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            isSelecting = true
            super.mouseDown(with: event)
            isSelecting = false
            selectionInteractionEnded?()
        }

        override func selectAll(_ sender: Any?) {
            explicitlyPaused = (textStorage?.length ?? 0) > 0
            super.selectAll(sender)
            selectionInteractionEnded?()
        }

        override func cancelOperation(_ sender: Any?) {
            transcriptCoordinator?.resumeLive(sender)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            transcriptCoordinator?.addTranscriptActions(to: menu)
            return menu
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSMenuItemValidation {
        weak var textView: SelectionTextView?
        var pending: LiveTranscriptTextView?
        private var rendered: LiveTranscriptTextView?
        // UTF-16 offsets, one per segment plus an end sentinel; NSTextStorage uses UTF-16.
        private var offsets = [0]
        private var applying = false
        private var appliedFontSize: TranscriptFontSize?
        private var appliedTranslationOnly: Bool?
        private var lastResumeRequest: UInt64 = 0
        private var forceFollow = false
        private(set) var isPaused = false

        enum CopyKind { case original, translation, timestamped }

        private struct ParagraphEdit {
            let oldIndices: Range<Int>
            let range: NSRange
            let replacement: NSAttributedString
            let lengths: [Int]
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying else { return }
            if textView?.selectedRanges.allSatisfy({ $0.rangeValue.length == 0 }) == true {
                textView?.explicitlyPaused = false
            }
            // Do not mutate text storage during AppKit's selection notification.
            DispatchQueue.main.async { [weak self] in self?.renderPending() }
        }

        func renderPending() {
            guard !applying, let text = textView, !text.isSelecting,
                  let next = pending, let storage = text.textStorage else { return }
            applying = true
            defer { applying = false }
            if lastResumeRequest != next.resumeRequest {
                lastResumeRequest = next.resumeRequest
                clearPause(text)
                forceFollow = true
            }
            let modeChanged = appliedTranslationOnly != nil
                && appliedTranslationOnly != next.translationOnly
            // A deliberate display-mode change takes effect immediately. A font change,
            // however, only changes attributes and keeps the current character selection.
            if modeChanged { clearPause(text) }
            let scroll = text.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let visible = scroll?.documentVisibleRect ?? .zero
            var ranges = text.selectedRanges.map(\.rangeValue)
            let selections = ranges.filter { $0.length > 0 }
            let follow = selections.isEmpty && (forceFollow || storage.length == 0
                || text.bounds.maxY - visible.maxY < 40)
            if appliedFontSize != next.fontSize {
                storage.addAttribute(.font, value: Self.font(next.fontSize),
                                     range: NSRange(location: 0, length: storage.length))
                appliedFontSize = next.fontSize
            }
            if text.explicitlyPaused {
                setPaused(true)
                return
            }
            if let old = rendered, old.revision == next.revision, !modeChanged {
                setPaused(false)
                if forceFollow { text.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
                forceFollow = false
                return
            }

            let edits = paragraphEdits(from: rendered, to: next, modeChanged: modeChanged)
            guard edits.allSatisfy({ edit in
                selections.allSatisfy { selection in
                    if edit.range.length == 0 {
                        return !(selection.location < edit.range.location
                            && edit.range.location < NSMaxRange(selection))
                    }
                    return NSIntersectionRange(selection, edit.range).length == 0
                }
            }) else {
                setPaused(true)
                return
            }

            // Descending edits keep all old UTF-16 positions valid, even when an earlier
            // translation and a new tail arrive together. Only affected rows are rebuilt.
            storage.beginEditing()
            for edit in edits.reversed() {
                let delta = edit.replacement.length - edit.range.length
                ranges = ranges.map { range in
                    if range.location >= NSMaxRange(edit.range) {
                        return NSRange(location: range.location + delta, length: range.length)
                    }
                    if range.length == 0, range.location > edit.range.location {
                        return NSRange(location: edit.range.location, length: 0)
                    }
                    return range
                }
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                var end = edit.range.location
                let ends = edit.lengths.map { length -> Int in end += length; return end }
                offsets.replaceSubrange((edit.oldIndices.lowerBound + 1)..<(edit.oldIndices.upperBound + 1), with: ends)
                let suffixStart = edit.oldIndices.lowerBound + ends.count + 1
                if delta != 0, suffixStart < offsets.count {
                    for index in suffixStart..<offsets.count { offsets[index] += delta }
                }
            }
            storage.endEditing()
            text.setSelectedRanges(ranges.map { NSValue(range: $0) },
                                   affinity: text.selectionAffinity, stillSelecting: false)
            rendered = next
            appliedTranslationOnly = next.translationOnly
            setPaused(false)
            forceFollow = false
            if follow {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            } else if let scroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func paragraphEdits(from old: LiveTranscriptTextView?, to next: LiveTranscriptTextView,
                                    modeChanged: Bool) -> [ParagraphEdit] {
            let oldCount = old?.segments.count ?? 0
            let commonCount = min(oldCount, next.segments.count)
            func equal(_ index: Int) -> Bool {
                guard let old, !modeChanged else { return false }
                return (next.translationOnly || old.segments[index].text == next.segments[index].text)
                    && Self.translation(old, index) == Self.translation(next, index)
            }
            var index = 0
            if !modeChanged, let old, old.revision == next.sourceRevision, let dirty = next.dirtyFrom {
                index = min(max(0, dirty), commonCount)
            }
            var edits: [ParagraphEdit] = []
            func append(_ oldIndices: Range<Int>, _ newIndices: Range<Int>) {
                let replacement = NSMutableAttributedString(string: "")
                let lengths = newIndices.map { index -> Int in
                    let row = Self.row(next, index)
                    replacement.append(row)
                    return row.length
                }
                let range = NSRange(location: offsets[oldIndices.lowerBound],
                                    length: offsets[oldIndices.upperBound] - offsets[oldIndices.lowerBound])
                edits.append(ParagraphEdit(oldIndices: oldIndices, range: range,
                                           replacement: replacement, lengths: lengths))
            }
            while index < commonCount {
                if equal(index) { index += 1; continue }
                let first = index
                repeat { index += 1 } while index < commonCount && !equal(index)
                append(first..<index, first..<index)
            }
            if oldCount != next.segments.count {
                append(commonCount..<oldCount, commonCount..<next.segments.count)
            }
            return edits
        }

        private static func font(_ size: TranscriptFontSize) -> NSFont {
            NSFont.systemFont(ofSize: size == .small ? 11 : (size == .large ? 15 : 13))
        }

        private static func translation(_ model: LiveTranscriptTextView, _ index: Int) -> String {
            index < model.translations.count ? model.translations[index] : ""
        }

        private static func row(_ model: LiveTranscriptTextView, _ index: Int) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(model.fontSize), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            let result = NSMutableAttributedString(string: "")
            let original = model.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = translation(model, index).trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.translationOnly, !original.isEmpty {
                result.append(NSAttributedString(string: original + "\n", attributes: attributes))
            }
            if !translated.isEmpty {
                attributes[.foregroundColor] = NSColor.systemTeal
                result.append(NSAttributedString(string: translated + "\n", attributes: attributes))
            }
            return result
        }

        private func setPaused(_ value: Bool) {
            guard isPaused != value else { return }
            isPaused = value
            // Updating a SwiftUI binding synchronously from updateNSView is not allowed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPaused == value else { return }
                self.pending?.onPauseChanged?(value)
            }
        }

        private func clearPause(_ text: SelectionTextView) {
            text.explicitlyPaused = false
            text.setSelectedRange(NSRange(location: min(text.selectedRange().location, text.string.utf16.count), length: 0))
        }

        @objc func resumeLive(_ sender: Any?) {
            guard let text = textView else { return }
            clearPause(text)
            forceFollow = true
            renderPending()
        }

        func copyText(_ kind: CopyKind) -> String {
            guard let shown = rendered, let text = textView else { return "" }
            let selected = text.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            return shown.segments.indices.compactMap { index -> String? in
                let row = NSRange(location: offsets[index], length: offsets[index + 1] - offsets[index])
                guard selected.contains(where: { NSIntersectionRange($0, row).length > 0 }) else { return nil }
                let original = shown.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                let translated = Self.translation(shown, index).trimmingCharacters(in: .whitespacesAndNewlines)
                switch kind {
                case .original: return original.isEmpty ? nil : original
                case .translation: return translated.isEmpty ? nil : translated
                case .timestamped:
                    let seconds = max(0, Int(shown.segments[index].start))
                    let stamp = String(format: "[%02d:%02d:%02d]", seconds / 3600, seconds / 60 % 60, seconds % 60)
                    let body = [original, translated].filter { !$0.isEmpty }.joined(separator: "\n")
                    return body.isEmpty ? nil : "\(stamp) \(body)"
                }
            }.joined(separator: "\n")
        }

        private func copy(_ kind: CopyKind) {
            let value = copyText(kind)
            guard !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        @objc private func copyOriginal(_ sender: Any?) { copy(.original) }
        @objc private func copyTranslation(_ sender: Any?) { copy(.translation) }
        @objc private func copyTimestamped(_ sender: Any?) { copy(.timestamped) }

        func addTranscriptActions(to menu: NSMenu) {
            // AppKit may reuse a context menu for subsequent right-clicks.
            let transcriptActionTag = 145701
            for item in menu.items where item.tag == transcriptActionTag {
                menu.removeItem(item)
            }
            let separator = NSMenuItem.separator()
            separator.tag = transcriptActionTag
            menu.addItem(separator)
            for (title, action) in [
                ("Copy Selected Paragraphs — Original", #selector(copyOriginal(_:))),
                ("Copy Selected Paragraphs — Translation", #selector(copyTranslation(_:))),
                ("Copy Selected Paragraphs with Timestamps", #selector(copyTimestamped(_:))),
                ("Resume Live Updates", #selector(resumeLive(_:)))
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = transcriptActionTag
                menu.addItem(item)
            }
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(resumeLive(_:)) { return isPaused }
            if menuItem.action == #selector(copyOriginal(_:)) { return !copyText(.original).isEmpty }
            if menuItem.action == #selector(copyTranslation(_:)) { return !copyText(.translation).isEmpty }
            if menuItem.action == #selector(copyTimestamped(_:)) { return !copyText(.timestamped).isEmpty }
            return true
        }
    }
}
