import SwiftUI
import AppKit

/// One selectable document. Disjoint paragraph edits preserve unaffected selections.
/// Character-level patches track selections through recognition corrections without pausing.
struct LiveTranscriptTextView: NSViewRepresentable {
    let segments: [TranscriptionSegment]
    let translations: [String]
    let revision: UInt64
    let fontSize: TranscriptFontSize
    let translationOnly: Bool
    // Optional producer hint. Skipped revisions always fall back to exact comparisons.
    var sourceRevision: UInt64? = nil
    var dirtyFrom: Int? = nil

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
        weak var transcriptCoordinator: Coordinator?
        var selectionInteractionEnded: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            isSelecting = true
            super.mouseDown(with: event)
            isSelecting = false
            selectionInteractionEnded?()
        }

        override func cancelOperation(_ sender: Any?) {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
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

        enum CopyKind { case original, translation, timestamped }

        private struct ParagraphEdit {
            let oldIndices: Range<Int>
            let range: NSRange
            let replacement: NSAttributedString
            let lengths: [Int]
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying else { return }
            // Do not mutate text storage during AppKit's selection notification.
            DispatchQueue.main.async { [weak self] in self?.renderPending() }
        }

        func renderPending() {
            guard !applying, let text = textView, !text.isSelecting,
                  let next = pending, let storage = text.textStorage else { return }
            applying = true
            defer { applying = false }
            let modeChanged = appliedTranslationOnly != nil
                && appliedTranslationOnly != next.translationOnly
            // A deliberate display-mode change takes effect immediately. A font change,
            // however, only changes attributes and keeps the current character selection.
            if modeChanged { text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0)) }
            let scroll = text.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let visible = scroll?.documentVisibleRect ?? .zero
            var ranges = text.selectedRanges.map(\.rangeValue)
            let selections = ranges.filter { $0.length > 0 }
            let follow = selections.isEmpty && (storage.length == 0
                || text.bounds.maxY - visible.maxY < 40)
            if appliedFontSize != next.fontSize {
                storage.addAttribute(.font, value: Self.font(next.fontSize),
                                     range: NSRange(location: 0, length: storage.length))
                appliedFontSize = next.fontSize
            }
            if let old = rendered, old.revision == next.revision, !modeChanged {
                return
            }

            let edits = paragraphEdits(from: rendered, to: next, modeChanged: modeChanged)
            // If an earlier paragraph changes height, keep the selected text at the
            // same screen position rather than merely preserving the scroll offset.
            let anchorIndex = ranges.firstIndex { $0.length > 0 }
            let anchorY: CGFloat? = anchorIndex.flatMap { index in
                edits.contains { $0.range.location < ranges[index].location }
                    ? Self.characterY(ranges[index].location, in: text) : nil
            }

            // Descending edits keep all old UTF-16 positions valid, even when an earlier
            // translation and a new tail arrive together. Only affected rows are rebuilt.
            storage.beginEditing()
            for edit in edits.reversed() {
                let delta = edit.replacement.length - edit.range.length
                // Preserve unchanged characters even inside a changed paragraph (e.g.
                // translation appended below a selected original, or one corrected word).
                let patch = modeChanged ? (edit.range, edit.replacement)
                    : Self.characterPatch(storage: storage, range: edit.range, replacement: edit.replacement)
                ranges = ranges.map { Self.mapSelection($0, through: patch.0, replacementLength: patch.1.length) }
                storage.replaceCharacters(in: patch.0, with: patch.1)
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
            if follow {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            } else if let scroll {
                var target = origin
                if let anchorY, let index = anchorIndex, ranges[index].length > 0,
                   let newY = Self.characterY(ranges[index].location, in: text) {
                    target.y += newY - anchorY
                }
                scroll.contentView.scroll(to: target)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private static func characterY(_ location: Int, in text: NSTextView) -> CGFloat? {
            guard location < (text.textStorage?.length ?? 0),
                  let layout = text.layoutManager, let container = text.textContainer else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).minY
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

        /// Trim common grapheme clusters, never splitting emoji/surrogate pairs.
        private static func characterPatch(storage: NSTextStorage, range: NSRange,
                                           replacement: NSAttributedString) -> (NSRange, NSAttributedString) {
            let old = Array((storage.string as NSString).substring(with: range))
            let new = Array(replacement.string)
            var prefix = 0, prefixLength = 0
            while prefix < min(old.count, new.count),
                  String(old[prefix]).utf16.elementsEqual(String(new[prefix]).utf16) {
                prefixLength += String(old[prefix]).utf16.count
                prefix += 1
            }
            var suffix = 0, suffixLength = 0
            while suffix < min(old.count, new.count) - prefix,
                  String(old[old.count - suffix - 1]).utf16.elementsEqual(String(new[new.count - suffix - 1]).utf16) {
                suffixLength += String(old[old.count - suffix - 1]).utf16.count
                suffix += 1
            }
            let changed = NSRange(location: range.location + prefixLength,
                                  length: range.length - prefixLength - suffixLength)
            let inserted = replacement.attributedSubstring(from: NSRange(location: prefixLength,
                length: replacement.length - prefixLength - suffixLength))
            return (changed, inserted)
        }

        /// Insertions at the selection end stay outside it (including Cmd+A + append).
        /// Corrections inside a selection remain selected; deleted selections collapse.
        static func mapSelection(_ selection: NSRange, through edit: NSRange,
                                 replacementLength: Int) -> NSRange {
            let delta = replacementLength - edit.length
            func map(_ position: Int, end: Bool) -> Int {
                if edit.length == 0 {
                    return position > edit.location || (position == edit.location && !end)
                        ? position + delta : position
                }
                if position <= edit.location { return position }
                if position >= NSMaxRange(edit) { return position + delta }
                return edit.location + (end ? replacementLength : 0)
            }
            let start = map(selection.location, end: false)
            let end = selection.length == 0 ? start : map(NSMaxRange(selection), end: true)
            return NSRange(location: start, length: max(0, end - start))
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
                ("Copy Selected Paragraphs with Timestamps", #selector(copyTimestamped(_:)))
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = transcriptActionTag
                menu.addItem(item)
            }
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(copyOriginal(_:)) { return !copyText(.original).isEmpty }
            if menuItem.action == #selector(copyTranslation(_:)) { return !copyText(.translation).isEmpty }
            if menuItem.action == #selector(copyTimestamped(_:)) { return !copyText(.timestamped).isEmpty }
            return true
        }
    }
}
