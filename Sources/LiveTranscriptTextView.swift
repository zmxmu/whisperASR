import SwiftUI
import AppKit

/// One selectable document. Stable paragraphs stay in NSTextStorage; only the changed
/// suffix is replaced. Selecting text freezes presentation, not capture or inference.
struct LiveTranscriptTextView: NSViewRepresentable {
    let segments: [TranscriptionSegment]
    let translations: [String]
    let revision: UInt64
    let fontSize: TranscriptFontSize
    let translationOnly: Bool

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
        text.delegate = coordinator
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
        var selectionInteractionEnded: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            isSelecting = true
            super.mouseDown(with: event)
            isSelecting = false
            selectionInteractionEnded?()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: SelectionTextView?
        var pending: LiveTranscriptTextView?
        private var rendered: LiveTranscriptTextView?
        // UTF-16 offsets, one per segment plus an end sentinel; NSTextStorage uses UTF-16.
        private var offsets = [0]
        private var applying = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying else { return }
            // Do not mutate text storage during AppKit's selection notification.
            DispatchQueue.main.async { [weak self] in self?.renderPending() }
        }

        func renderPending() {
            guard !applying, let text = textView, !text.isSelecting,
                  text.selectedRanges.allSatisfy({ $0.rangeValue.length == 0 }),
                  let next = pending, let storage = text.textStorage else { return }
            let styleChanged = rendered?.fontSize != next.fontSize
                || rendered?.translationOnly != next.translationOnly
            if let old = rendered, old.revision == next.revision, !styleChanged { return }

            var first = 0
            if let old = rendered, !styleChanged {
                let limit = min(old.segments.count, next.segments.count)
                while first < limit {
                    let oldTranslation = first < old.translations.count ? old.translations[first] : ""
                    let newTranslation = first < next.translations.count ? next.translations[first] : ""
                    guard old.segments[first].text == next.segments[first].text,
                          oldTranslation == newTranslation else { break }
                    first += 1
                }
                if first == old.segments.count, first == next.segments.count {
                    rendered = next
                    return
                }
            }

            let scroll = text.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let visible = scroll?.documentVisibleRect ?? .zero
            let follow = storage.length == 0 || text.bounds.maxY - visible.maxY < 40
            let pointSize: CGFloat = next.fontSize == .small ? 11 : (next.fontSize == .large ? 15 : 13)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: pointSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            let replacement = NSMutableAttributedString(string: "")
            let start = offsets[first]
            offsets.removeSubrange((first + 1)..<offsets.count)
            for index in first..<next.segments.count {
                let original = next.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                let translated = index < next.translations.count
                    ? next.translations[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !next.translationOnly, !original.isEmpty {
                    replacement.append(NSAttributedString(string: original + "\n", attributes: attributes))
                }
                if !translated.isEmpty {
                    var translationAttributes = attributes
                    translationAttributes[.foregroundColor] = NSColor.systemTeal
                    replacement.append(NSAttributedString(string: translated + "\n", attributes: translationAttributes))
                }
                offsets.append(start + replacement.length)
            }
            applying = true
            let caret = min(text.selectedRange().location, start)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: replacement)
            storage.endEditing()
            text.setSelectedRange(NSRange(location: caret, length: 0))
            rendered = next
            if follow {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            } else if let scroll {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            applying = false
        }
    }
}
