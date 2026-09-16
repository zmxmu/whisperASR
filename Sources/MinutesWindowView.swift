import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Meeting Minutes Window

struct MinutesWindowView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openSettings) private var openSettings
    @State private var generator = MinutesGenerator.shared
    @State private var promptStore = MinutesPromptStore.shared
    @State private var copyConfirmation = false

    var body: some View {
        Group {
            switch generator.phase {
            case .idle:
                placeholder

            case .generating(let status):
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text(status)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { generator.cancel() }
                }
                .padding()

            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text("Couldn't Generate Minutes")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                    HStack(spacing: 12) {
                        Button("Open Settings…") { openSettings() }
                        if sourceItem != nil {
                            Button("Try Again") { regenerate(with: promptStore.selectedPrompt) }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .padding()

            case .completed:
                HTMLView(html: generator.fullHTMLDocument)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle(generator.itemName.isEmpty ? "Meeting Minutes" : "Minutes — \(generator.itemName)")
        .navigationSubtitle(generator.promptName)
        .toolbar {
            ToolbarItem {
                HStack(spacing: 4) {
                    if sourceItem != nil {
                        Menu {
                            ForEach(promptStore.prompts) { prompt in
                                Button {
                                    regenerate(with: prompt)
                                } label: {
                                    HStack {
                                        Text(prompt.name)
                                        if promptStore.selectedPromptID == prompt.id {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .menuIndicator(.hidden)
                        .disabled(isGenerating)
                        .help("Regenerate the minutes with a prompt")
                    }

                    Menu {
                        Button("Copy Formatted") { copyFormatted() }
                        Button("Copy HTML Source") { copyHTMLSource() }
                    } label: {
                        Label("Copy", systemImage: copyConfirmation ? "checkmark" : "doc.on.doc")
                    }
                    .menuIndicator(.hidden)
                    .disabled(generator.phase != .completed)
                    .help("Copy the minutes")

                    Button {
                        exportHTML()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(generator.phase != .completed)
                    .help("Export the minutes as an HTML file")
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("Open a transcript and choose Meeting Minutes in the toolbar")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var isGenerating: Bool {
        if case .generating = generator.phase { return true }
        return false
    }

    /// The item the current minutes were generated from, if it still exists.
    private var sourceItem: TranscriptionItem? {
        guard let id = generator.sourceItemID else { return nil }
        return appState.items.first { $0.id == id }
    }

    private func regenerate(with prompt: MinutesPrompt) {
        guard let item = sourceItem else { return }
        promptStore.selectedPromptID = prompt.id
        generator.generate(item: item, prompt: prompt)
    }

    // MARK: Copy & Export

    /// Copies rich text (RTF + HTML flavors) so pasting into Mail, Word, Google
    /// Docs, etc. keeps the formatting; plain-text apps get the visible text.
    private func copyFormatted() {
        let html = generator.fullHTMLDocument
        guard let data = html.data(using: .utf8) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtf, .html, .string], owner: nil)
        pasteboard.setString(html, forType: .html)

        if let attributed = NSAttributedString(
            html: data,
            options: [.characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil) {
            let range = NSRange(location: 0, length: attributed.length)
            if let rtf = attributed.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pasteboard.setData(rtf, forType: .rtf)
            }
            pasteboard.setString(attributed.string, forType: .string)
        } else {
            pasteboard.setString(generator.htmlFragment, forType: .string)
        }
        flashCopyConfirmation()
    }

    private func copyHTMLSource() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generator.fullHTMLDocument, forType: .string)
        flashCopyConfirmation()
    }

    private func flashCopyConfirmation() {
        copyConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copyConfirmation = false
        }
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        let baseName = (generator.itemName as NSString).deletingPathExtension
        panel.nameFieldStringValue = (baseName.isEmpty ? "Meeting" : baseName) + " minutes.html"

        let html = generator.fullHTMLDocument
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - WKWebView wrapper

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        /// Open clicked links in the default browser instead of navigating the
        /// minutes view away.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
