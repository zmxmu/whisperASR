import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var isAlwaysOnTop = false
    @State private var translationOnly = false

    var body: some View {
        VStack(spacing: 0) {
            switch recorder.state {
            case .recording:
                recordingContent
            case .saving:
                savingContent
            default:
                Color.clear
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: appState.enableLiveTranscription ? 200 : 44,
            idealHeight: appState.enableLiveTranscription ? 300 : 44,
            maxHeight: appState.enableLiveTranscription ? .infinity : 44
        )
        .background(WindowConfigurator())
    }

    // MARK: - Recording

    // The transcript pane and the duration label are separate views so that a live-text
    // update re-evaluates only the pane, and the 1 Hz duration tick only the label —
    // neither re-runs this whole body (and the NSViewRepresentable update) every second.
    private var recordingContent: some View {
        VStack(spacing: 0) {
            // Live transcription area (only shown if enabled)
            if appState.enableLiveTranscription {
                LiveTranscriptPane(translationOnly: translationOnly)
                Divider()
            }

            // Bottom bar: indicator + action buttons + window controls
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 4)
                        .modifier(PulsingModifier())
                    RecordingDurationLabel()
                }

                Spacer()

                Button("Cancel") {
                    appState.stopLiveTranscription()
                    recorder.cancelRecording()
                    dismiss()
                }

                Button("Finish Recording") {
                    stopAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Divider()
                    .frame(height: 16)

                if appState.enableLiveTranslation {
                    Button {
                        appState.setLiveTranslationPaused(!appState.liveTranslationPaused)
                    } label: {
                        Image(systemName: appState.liveTranslationPaused ? "character.bubble" : "character.bubble.fill")
                            .foregroundStyle(appState.liveTranslationPaused ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .help(appState.liveTranslationPaused ? "Resume translation" : "Pause translation (e.g. speaker switched to your language)")

                    Button {
                        translationOnly.toggle()
                    } label: {
                        Image(systemName: translationOnly ? "eye.fill" : "eye")
                            .foregroundStyle(translationOnly ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(translationOnly ? "Show original and translation" : "Show translation only")
                }

                Button {
                    isAlwaysOnTop.toggle()
                    setWindowAlwaysOnTop(isAlwaysOnTop)
                } label: {
                    Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(isAlwaysOnTop ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isAlwaysOnTop ? "Unpin window" : "Keep on top of all windows")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if appState.enableLiveTranscription, !appState.isLiveTranscribing {
                appState.startLiveTranscription(recorder: recorder)
            }
            if recorder.pinWindow {
                recorder.pinWindow = false
                isAlwaysOnTop = true
                setWindowAlwaysOnTop(true)
            }
        }
    }

    // MARK: - Saving

    private var savingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Saving recording...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func stopAndDismiss() {
        Task {
            await appState.finishRecording(recorder: recorder)
            dismiss()
        }
    }

    private func setWindowAlwaysOnTop(_ alwaysOnTop: Bool) {
        NSApplication.shared.windows
            .first { $0.title == "Recording" }?
            .level = alwaysOnTop ? .floating : .normal
    }
}

// MARK: - Live Transcript Pane

/// Observes only the live-transcript state, so whisper updates re-evaluate this view alone.
private struct LiveTranscriptPane: View {
    @Environment(AppState.self) private var appState
    @AppStorage("transcriptFontSize") private var transcriptFontSizeRaw = TranscriptFontSize.normal.rawValue
    let translationOnly: Bool

    private var fontSize: TranscriptFontSize { TranscriptFontSize(rawValue: transcriptFontSizeRaw) ?? .normal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = appState.liveError {
                errorBanner(message: message, tint: .red)
            }
            if let message = appState.liveTranslationError {
                errorBanner(message: message, tint: .orange)
            }
            if appState.isLiveTranscribing && appState.liveSegments.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for audio...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
            }

            if !appState.liveSegments.isEmpty {
                LiveTranscriptTextView(
                    segments: appState.liveSegments,
                    translations: appState.liveTranslatedSegments,
                    revision: appState.liveTextRevision,
                    fontSize: fontSize,
                    translationOnly: translationOnly
                )
                .help("Drag to select across lines; ⌘C copies. Earlier text stays selected while new text keeps arriving; a selection that includes the newest line pauses display updates until you click.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(message: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

// MARK: - Recording Duration Label

/// Observes only `recordingDuration`, so the 1 Hz tick re-renders this label alone.
private struct RecordingDurationLabel: View {
    @Environment(AudioRecorder.self) private var recorder

    var body: some View {
        Text(Self.format(recorder.recordingDuration))
            .font(.system(size: 13, weight: .light, design: .monospaced))
    }

    private static func format(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Window Configurator

/// Hides traffic lights and enables drag-to-move on the Recording window.
private struct WindowConfigurator: NSViewRepresentable {
    class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Pulsing Animation

/// Pulses opacity 1.0 → 0.4 on a 1.6s cycle. Driven by a single repeating
/// Core Animation, not a TimelineView — a 10Hz timeline re-evaluated SwiftUI
/// continuously for the whole recording session, exactly when the CPU is
/// already busy with capture + live whisper.
private struct PulsingModifier: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
