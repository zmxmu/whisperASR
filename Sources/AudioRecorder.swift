import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os
import CoreGraphics
import Darwin

enum RecordingState: Equatable {
    case idle
    case loading
    case ready
    case recording
    case saving
    case permissionDenied
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var state: RecordingState = .idle
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    var recordingDuration: TimeInterval = 0
    var error: String?
    var meetingEnded = false
    var includeMicrophone = false
    var onMeetingEnded: (() -> Void)?
    var customRecordingName: String?
    var pinWindow = false

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?
    private var outputURL: URL?
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var meetingStarted = false

    // Stream watchdog: detect stalled audio delivery and restart
    private var lastAudioBufferTime = OSAllocatedUnfairLock(initialState: Date())
    private var audioWatchdogTimer: Timer?
    private var recordingApp: SCRunningApplication?
    private var isRestartingStream = false
    @ObservationIgnored private var streamRestartTask: Task<Void, Never>?
    /// Reused across watchdog restarts, so stopping can drain every audio callback.
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "com.whisperasr.audio-capture")
    // A nil identity closes the gate. Updates are ordered on captureQueue; the
    // lock also lets its Sendable box cross the async queue boundary safely.
    @ObservationIgnored private let acceptedStream = OSAllocatedUnfairLock(initialState: Optional<ObjectIdentifier>.none)
    /// How long without audio before we consider the stream stalled (seconds).
    private static let audioStallThreshold: TimeInterval = 15

    // Microphone mixing
    private var audioEngine: AVAudioEngine?
    private var micSampleBuffer = OSAllocatedUnfairLock(initialState: [Float]())
    private var isMicActive = false
    private static let maxMicBufferSamples = 48000 * 5 // 5 seconds cap

    @ObservationIgnored private let pcmBuffer = LiveAudioBuffer()

    // 48kHz → 16kHz resampler for live transcription (AVAudioConverter applies
    // a proper anti-alias low-pass filter; naive decimation aliased above 8kHz).
    private static let pcmSourceFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private static let pcmTargetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    @ObservationIgnored
    private lazy var pcmResampler: AVAudioConverter? = {
        AVAudioConverter(from: AudioRecorder.pcmSourceFormat, to: AudioRecorder.pcmTargetFormat)
    }()
    /// Total number of 16kHz samples accumulated since recording started (absolute count).
    var accumulatedSampleCount: Int {
        pcmBuffer.availableRange.upperBound
    }

    var oldestAvailableSample: Int {
        pcmBuffer.availableRange.lowerBound
    }

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - Live Transcription PCM Access

    func transcriptionSnapshot(from startIndex: Int, maximumCount: Int) -> LiveAudioSnapshot {
        pcmBuffer.snapshot(from: startIndex, maximumCount: maximumCount)
    }

    /// Trim committed samples from the front of the PCM buffer to cap memory usage.
    /// `upTo` is an absolute sample index — samples before this index are freed.
    func trimSamples(upTo absoluteIndex: Int) {
        pcmBuffer.trim(upTo: absoluteIndex)
    }

    /// Clears the accumulated PCM sample buffer (called when recording ends).
    func clearTranscriptionBuffer() {
        pcmBuffer.clear()
    }

    // MARK: - App List

    func loadAvailableApps() {
        state = .loading
        error = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications
                    .filter {
                        $0.bundleIdentifier != myBundleID
                            && !$0.applicationName.isEmpty
                            && appsWithWindows.contains($0.bundleIdentifier)
                            && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                    }
                    .sorted { ($0.applicationName) < ($1.applicationName) }

                await MainActor.run {
                    self.availableApps = apps
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code == -3801 || "\(error)".contains("denied") {
                        self.state = .permissionDenied
                    } else {
                        self.error = error.localizedDescription
                        self.state = .permissionDenied
                    }
                }
            }
        }
    }

    // MARK: - Start Recording

    private static let recentAppsKey = "recentRecordingApps"

    /// Bundle IDs of recently recorded apps, most recent first.
    var recentAppBundleIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []
    }

    private func saveRecentApp(bundleID: String) {
        var recent = recentAppBundleIDs
        recent.removeAll { $0 == bundleID }
        recent.insert(bundleID, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        UserDefaults.standard.set(recent, forKey: Self.recentAppsKey)
    }

    func startRecording(app: SCRunningApplication) {
        guard state == .ready else { return }
        saveRecentApp(bundleID: app.bundleIdentifier)

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await MainActor.run {
                        self.error = "No display found"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                // Minimal video config (required but we don't need video)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let fileURL = self.makeOutputURL(appName: app.applicationName)
                self.customRecordingName = nil

                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                self.assetWriter = writer
                self.assetWriterInput = input
                self.outputURL = fileURL
                self._hasReceivedSamples.withLock { $0 = false }
                self.clearTranscriptionBuffer()
                self.pcmResampler?.reset()

                self.recordingApp = app

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                self.stream = stream
                await self.acceptAudio(from: stream)
                try await stream.startCapture()
                self.recordingAppName = app.applicationName

                if self.includeMicrophone {
                    do {
                        try self.startMicrophoneCapture()
                    } catch {
                        print("[AudioRecorder] failed to start microphone: \(error)")
                        await MainActor.run {
                            self.error = "Microphone unavailable, recording app audio only"
                        }
                    }
                }

                await MainActor.run {
                    self.state = .recording
                    self.recordingDuration = 0
                    self.recordingStartTime = Date()
                    self.timer = Self.commonModeTimer(interval: 1.0) { [weak self] in
                        guard let self, let start = self.recordingStartTime else { return }
                        self.recordingDuration = Date().timeIntervalSince(start)
                    }
                    self.startMeetingMonitor(app: app)
                    self.startAudioWatchdog()
                }
            } catch {
                // Tear down whatever got as far as starting: cancel the writer,
                // delete the stray output file, and drop the half-built stream so
                // the next attempt starts from a clean slate.
                if let stream = self.stream {
                    try? await stream.stopCapture()
                    try? stream.removeStreamOutput(self, type: .audio)
                    self.stream = nil
                }
                await self.drainCaptureQueue()
                if let writer = self.assetWriter {
                    writer.cancelWriting()
                }
                self.assetWriter = nil
                self.assetWriterInput = nil
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                    self.outputURL = nil
                }
                self.recordingApp = nil
                self.recordingAppName = nil
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Stop Recording

    @MainActor
    func stopRecording(preservePCM: Bool = false) async -> URL? {
        await MainActor.run {
            state = .saving
            timer?.invalidate()
            timer = nil
            stopMeetingMonitor()
            stopAudioWatchdog()
        }

        await stopCaptureAndDrain()
        stopMicrophoneCapture()
        if !preservePCM { clearTranscriptionBuffer() }
        recordingApp = nil

        let received = _hasReceivedSamples.withLock { $0 }
        print("[AudioRecorder] stopRecording: hasReceivedSamples=\(received), writer=\(assetWriter != nil), input=\(assetWriterInput != nil)")

        guard let writer = assetWriter, let input = assetWriterInput else {
            assetWriter = nil
            assetWriterInput = nil
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            print("[AudioRecorder] stopRecording: no writer/input, returning nil")
            return nil
        }

        input.markAsFinished()
        await writer.finishWriting()

        print("[AudioRecorder] stopRecording: writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")

        let url: URL?
        if writer.status == .completed, received {
            url = outputURL
        } else {
            url = nil
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        assetWriter = nil
        assetWriterInput = nil

        print("[AudioRecorder] stopRecording: returning url=\(String(describing: url))")
        return url
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        Task { @MainActor in
            self.state = .saving
            self.stopAudioWatchdog()
            await self.stopCaptureAndDrain()
            self.stopMicrophoneCapture()
            self.clearTranscriptionBuffer()
            self.recordingApp = nil

            if let writer = assetWriter {
                writer.cancelWriting()
                if let url = outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
                assetWriter = nil
                assetWriterInput = nil
            }

            await MainActor.run {
                state = .ready
                timer?.invalidate()
                timer = nil
                stopMeetingMonitor()
                stopAudioWatchdog()
                recordingDuration = 0
            }
        }
    }

    @MainActor
    private func stopCaptureAndDrain() async {
        // A watchdog restart must not publish a replacement stream after Finish.
        let restart = streamRestartTask
        restart?.cancel()
        await restart?.value
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .audio)
            self.stream = nil
        }
        await drainCaptureQueue()
    }

    private func drainCaptureQueue() async {
        let gate = acceptedStream
        await withCheckedContinuation { continuation in
            captureQueue.async {
                // Everything submitted before this barrier has completed. Any
                // unexpectedly late callback is rejected before touching PCM/writer.
                gate.withLock { $0 = nil }
                continuation.resume()
            }
        }
    }

    private func acceptAudio(from stream: SCStream) async {
        let gate = acceptedStream
        let identity = ObjectIdentifier(stream)
        await withCheckedContinuation { continuation in
            captureQueue.async {
                gate.withLock { $0 = identity }
                continuation.resume()
            }
        }
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Target format matching SCStream output: 48kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

        let needsConversion = hwFormat.sampleRate != 48000 || hwFormat.channelCount != 1
        var converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var samples: [Float]
            if let converter {
                let ratio = 48000.0 / hwFormat.sampleRate
                let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
                var error: NSError?
                var consumed = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0,
                      let channelData = converted.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
            } else {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            }

            let capturedSamples = samples
            self.micSampleBuffer.withLock { buf in
                buf.append(contentsOf: capturedSamples)
                // Cap buffer size to prevent unbounded growth
                if buf.count > Self.maxMicBufferSamples {
                    buf.removeFirst(buf.count - Self.maxMicBufferSamples)
                }
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        self.isMicActive = true
    }

    private func stopMicrophoneCapture() {
        guard isMicActive else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micSampleBuffer.withLock { $0.removeAll() }
        isMicActive = false
    }

    /// Creates a new CMSampleBuffer with mic audio mixed into the app audio.
    /// Returns nil if mixing is not needed or fails — caller should use the original buffer.
    private func mixedSampleBuffer(from original: CMSampleBuffer) -> CMSampleBuffer? {
        guard isMicActive else { return nil }
        guard let formatDesc = CMSampleBufferGetFormatDescription(original),
              let blockBuffer = CMSampleBufferGetDataBuffer(original) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        // Copy original audio data
        let sampleCount = totalLength / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: sampleCount)
        memcpy(&floats, dataPointer, totalLength)

        // Read matching mic samples and mix
        let micSamples = micSampleBuffer.withLock { buf -> [Float] in
            let count = min(sampleCount, buf.count)
            let result = Array(buf.prefix(count))
            buf.removeFirst(count)
            return result
        }
        for i in 0..<micSamples.count {
            let mixed = floats[i] + micSamples[i]
            floats[i] = max(-1.0, min(1.0, mixed))
        }

        // Create new block buffer with mixed data
        var newBlockBuffer: CMBlockBuffer?
        var res = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &newBlockBuffer
        )
        guard res == kCMBlockBufferNoErr, let newBlockBuffer else { return nil }

        res = floats.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: newBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: totalLength
            )
        }
        guard res == kCMBlockBufferNoErr else { return nil }

        // Create new sample buffer
        let numSamples = CMSampleBufferGetNumSamples(original)
        let pts = CMSampleBufferGetPresentationTimeStamp(original)

        var newSampleBuffer: CMSampleBuffer?
        res = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &newSampleBuffer
        )
        guard res == noErr else { return nil }

        return newSampleBuffer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioRecorder] SCStream stopped with error: \(error)")
        // Attempt to restart the stream automatically
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.restartStream()
        }
    }

    // MARK: - Audio Watchdog

    /// A repeating main-run-loop timer scheduled in `.common` modes, so it keeps
    /// firing during modal sessions (e.g. the Zoom meeting-ended NSAlert) — the
    /// default mode pauses there, which froze the duration display and stall
    /// watchdog for as long as the alert stayed open.
    private static func commonModeTimer(interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func startAudioWatchdog() {
        lastAudioBufferTime.withLock { $0 = Date() }
        audioWatchdogTimer = Self.commonModeTimer(interval: 5.0) { [weak self] in
            self?.checkAudioStall()
        }
    }

    private func stopAudioWatchdog() {
        audioWatchdogTimer?.invalidate()
        audioWatchdogTimer = nil
    }

    private func checkAudioStall() {
        guard state == .recording, !isRestartingStream else { return }
        let lastTime = lastAudioBufferTime.withLock { $0 }
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed > Self.audioStallThreshold {
            print("[AudioRecorder] audio stall detected: no buffers for \(String(format: "%.1f", elapsed))s, restarting stream")
            Task { @MainActor in self.restartStream() }
        }
    }

    @MainActor
    private func restartStream() {
        guard state == .recording, !isRestartingStream else { return }
        isRestartingStream = true

        streamRestartTask = Task { @MainActor in
            defer {
                self.isRestartingStream = false
                self.streamRestartTask = nil
            }
            // Stop the old stream
            if let oldStream = self.stream {
                try? await oldStream.stopCapture()
                try? oldStream.removeStreamOutput(self, type: .audio)
                self.stream = nil
            }
            await self.drainCaptureQueue()

            // Rebuild a fresh SCStream with the same app
            guard !Task.isCancelled, self.state == .recording,
                  let app = self.recordingApp else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled, self.state == .recording,
                      let display = content.displays.first else { return }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                self.stream = newStream
                await self.acceptAudio(from: newStream)
                try await newStream.startCapture()
                guard !Task.isCancelled, self.state == .recording else {
                    try? await newStream.stopCapture()
                    try? newStream.removeStreamOutput(self, type: .audio)
                    self.stream = nil
                    await self.drainCaptureQueue()
                    return
                }
                self.lastAudioBufferTime.withLock { $0 = Date() }

                print("[AudioRecorder] stream restarted successfully")
            } catch {
                if let failedStream = self.stream {
                    try? await failedStream.stopCapture()
                    try? failedStream.removeStreamOutput(self, type: .audio)
                    self.stream = nil
                }
                await self.drainCaptureQueue()
                print("[AudioRecorder] stream restart failed: \(error)")
            }

        }
    }

    // MARK: - Zoom Meeting Monitor

    private func startMeetingMonitor(app: SCRunningApplication) {
        guard Self.zoomBundleIDs.contains(app.bundleIdentifier) else { return }
        recordingPID = app.processID
        meetingStarted = false
        meetingEnded = false

        meetingMonitorTimer = Self.commonModeTimer(interval: 10.0) { [weak self] in
            self?.checkZoomMeetingWindows()
        }
    }

    private func stopMeetingMonitor() {
        meetingMonitorTimer?.invalidate()
        meetingMonitorTimer = nil
        recordingPID = nil
        meetingStarted = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        // Run the blocking ps check on a background thread to avoid stalling the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Check if Zoom's CptHost subprocess is running — it only exists during an active call.
            let hasMeeting = self.zoomHasActiveCall(parentPID: pid)

            DispatchQueue.main.async {
                if hasMeeting {
                    self.meetingStarted = true
                } else if self.meetingStarted {
                    self.meetingMonitorTimer?.invalidate()
                    self.meetingMonitorTimer = nil
                    self.meetingEnded = true
                    self.onMeetingEnded?()
                }
            }
        }
    }

    /// Returns true if Zoom's CptHost (call/meeting host) subprocess is running under the given parent PID.
    /// Uses Darwin syscalls instead of spawning a /bin/ps subprocess.
    private func zoomHasActiveCall(parentPID: pid_t) -> Bool {
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let byteCount = proc_listchildpids(parentPID, &childPIDs,
            Int32(childPIDs.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return false }
        let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
        for i in 0..<childCount {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(childPIDs[i], &pathBuf, UInt32(MAXPATHLEN)) > 0 {
                if String(cString: pathBuf).contains("CptHost") { return true }
            }
        }
        return false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptedStream.withLock({ $0 == ObjectIdentifier(stream) }) else { return }
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Track that we're still receiving audio (for stall detection)
        lastAudioBufferTime.withLock { $0 = Date() }

        // Use mixed buffer if mic is active, otherwise use original
        let bufferToWrite = mixedSampleBuffer(from: sampleBuffer) ?? sampleBuffer

        // Accumulate 16kHz PCM samples for live transcription
        accumulatePCMSamples(from: bufferToWrite)

        guard let input = assetWriterInput else {
            print("[AudioRecorder] stream callback: no assetWriterInput")
            return
        }
        guard input.isReadyForMoreMediaData else {
            print("[AudioRecorder] stream callback: input not ready")
            return
        }

        let success = input.append(bufferToWrite)
        if success {
            let wasFirst = _hasReceivedSamples.withLock { val -> Bool in
                let first = !val
                val = true
                return first
            }
            if wasFirst {
                print("[AudioRecorder] first audio sample appended, numSamples=\(bufferToWrite.numSamples)")
            }
        } else {
            print("[AudioRecorder] stream callback: append failed, writer.status=\(assetWriter?.status.rawValue ?? -1), error=\(String(describing: assetWriter?.error))")
        }
    }

    /// Extracts Float32 samples from a CMSampleBuffer (48kHz) and resamples to 16kHz
    /// via AVAudioConverter (applies anti-alias filter) for whisper.cpp.
    private func accumulatePCMSamples(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }

        let sampleCount = totalLength / MemoryLayout<Float>.size
        guard sampleCount > 0, let converter = pcmResampler else { return }

        let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)

        guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmSourceFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let inputChannel = inputBuffer.floatChannelData?[0] else { return }
        memcpy(inputChannel, floatPtr, sampleCount * MemoryLayout<Float>.size)
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // 48000 / 16000 = 3; +1 guards against rounding on non-multiples of 3.
        let outputCapacity = AVAudioFrameCount(sampleCount / 3 + 1)
        guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmTargetFormat, frameCapacity: outputCapacity) else { return }

        var convertError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard convertError == nil, outputBuffer.frameLength > 0,
              let outputChannel = outputBuffer.floatChannelData?[0] else { return }

        let resampled = Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
        pcmBuffer.append(resampled)
    }

    // MARK: - Output URL

    private func makeOutputURL(appName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH'h'"
        let timestamp = df.string(from: Date())
        let baseName: String
        if let custom = customRecordingName, !custom.isEmpty {
            let sanitized = custom.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        } else {
            let sanitized = appName.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        }
        var url = recordingsDir.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDir.appendingPathComponent("\(baseName) \(counter).m4a")
            counter += 1
        }
        return url
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
