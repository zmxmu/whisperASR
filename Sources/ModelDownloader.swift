import Foundation
import Observation

@Observable
final class ModelDownloader {
    enum State: Equatable {
        case prompt
        case downloading
        case completed
        case failed(String)
    }

    let model: WhisperModelInfo
    /// Called on the main queue after a successful download.
    private let onFinished: () -> Void

    var state: State = .prompt
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var estimatedTimeRemaining: String?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegate: DownloadDelegate?
    private var downloadStartTime: Date?
    private var downloadStartBytes: Int64 = 0

    /// Folder-download state (`.hfFolder` source). Files download sequentially
    /// into the staging directory, then the whole directory moves into place.
    private struct FolderFile {
        let relativePath: String
        let size: Int64
        let url: URL
    }
    private var folderQueue: [FolderFile] = []
    private var currentFolderFile: FolderFile?
    private var folderTotalBytes: Int64 = 0
    private var folderCompletedBytes: Int64 = 0
    /// Set before cancelling the in-flight task so the sequential folder chain
    /// doesn't start the next file after a user cancel.
    private var cancelRequested = false

    init(model: WhisperModelInfo, onFinished: @escaping () -> Void = {}) {
        self.model = model
        self.onFinished = onFinished
    }

    static func stagingDirectory(for model: WhisperModelInfo) -> URL {
        ModelCatalog.modelDirectory.appendingPathComponent(".partial-\(model.fileName)")
    }

    private var stagingDir: URL { Self.stagingDirectory(for: model) }

    private var resumeDataURL: URL {
        resumeDataURL(suffix: nil)
    }

    private func resumeDataURL(suffix: String?) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var name = ".download-resume-\(model.fileName)"
        if let suffix {
            name += "-" + suffix.replacingOccurrences(of: "/", with: "_")
        }
        return appSupport.appendingPathComponent("WhisperASR/\(name)")
    }

    private var currentResumeDataURL: URL {
        if let currentFolderFile {
            return resumeDataURL(suffix: currentFolderFile.relativePath)
        }
        return resumeDataURL
    }

    var hasResumeData: Bool {
        switch model.source {
        case .file:
            return FileManager.default.fileExists(atPath: resumeDataURL.path)
        case .hfFolder:
            return FileManager.default.fileExists(atPath: stagingDir.path)
        }
    }

    var progressText: String {
        let downloaded = String(format: "%.0f", Double(downloadedBytes) / 1_000_000)
        if totalBytes > 0 {
            let total = String(format: "%.0f", Double(totalBytes) / 1_000_000)
            return "\(downloaded) / \(total) MB"
        }
        let approx = String(format: "%.0f", Double(model.approxBytes) / 1_000_000)
        return "\(downloaded) / ~\(approx) MB"
    }

    func startDownload() {
        state = .downloading
        cancelRequested = false
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        estimatedTimeRemaining = nil
        downloadStartTime = Date()
        downloadStartBytes = 0

        switch model.source {
        case .file(let url):
            startTask(with: url, resumeBlob: resumeDataURL)
        case .hfFolder(let repo, let folder):
            folderQueue = []
            currentFolderFile = nil
            folderTotalBytes = 0
            folderCompletedBytes = 0
            Task { await self.startFolderDownload(repo: repo, folder: folder) }
        }
    }

    private func startTask(with url: URL, resumeBlob: URL) {
        let del = DownloadDelegate(downloader: self)
        self.delegate = del
        session = URLSession(configuration: .default, delegate: del, delegateQueue: nil)

        if let resumeData = try? Data(contentsOf: resumeBlob) {
            downloadTask = session?.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: resumeBlob)
        } else {
            downloadTask = session?.downloadTask(with: url)
        }

        downloadTask?.resume()
    }

    func cancelDownload() {
        state = .prompt
        cancelRequested = true
        downloadTask?.cancel(byProducingResumeData: { _ in
            // Resume data is saved in didCompleteWithError delegate
        })
    }

    // MARK: - Folder download (Hugging Face repo subtree)

    private func startFolderDownload(repo: String, folder: String) async {
        do {
            let files = try await Self.listFolderFiles(repo: repo, folder: folder)
            guard !files.isEmpty else {
                throw URLError(.resourceUnavailable)
            }
            folderTotalBytes = files.reduce(0) { $0 + $1.size }
            folderQueue = files
            DispatchQueue.main.async { self.totalBytes = self.folderTotalBytes }
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            guard !cancelRequested else { return }
            startNextFolderFile()
        } catch {
            DispatchQueue.main.async {
                self.state = .failed("Could not list model files: \(error.localizedDescription)")
            }
        }
    }

    private static func listFolderFiles(repo: String, folder: String) async throws -> [FolderFile] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(folder)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct TreeEntry: Decodable {
            let type: String
            let size: Int64?
            let path: String
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.compactMap { entry in
            guard entry.type == "file" else { return nil }
            let relative = String(entry.path.dropFirst(folder.count + 1))
            let escaped = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(escaped)") else { return nil }
            return FolderFile(relativePath: relative, size: entry.size ?? 0, url: url)
        }
    }

    /// Runs on the URLSession delegate queue (or the initial listing Task);
    /// files are strictly sequential so there is no concurrent mutation.
    private func startNextFolderFile() {
        guard !cancelRequested else { return }
        while let next = folderQueue.first {
            let staged = stagingDir.appendingPathComponent(next.relativePath)
            let stagedSize = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? nil
            if let stagedSize, stagedSize == next.size {
                // Already fully downloaded on a previous attempt — skip.
                folderQueue.removeFirst()
                folderCompletedBytes += next.size
                continue
            }
            folderQueue.removeFirst()
            currentFolderFile = next
            reportFolderProgress(currentFileBytes: 0)
            startTask(with: next.url, resumeBlob: resumeDataURL(suffix: next.relativePath))
            return
        }
        currentFolderFile = nil
        finalizeFolderDownload()
    }

    private func finalizeFolderDownload() {
        do {
            let dest = ModelCatalog.path(for: model)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: stagingDir, to: dest)
            DispatchQueue.main.async {
                self.state = .completed
                self.onFinished()
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .failed("Failed to save model: \(error.localizedDescription)")
            }
        }
    }

    private func reportFolderProgress(currentFileBytes: Int64) {
        let written = folderCompletedBytes + currentFileBytes
        let total = folderTotalBytes
        DispatchQueue.main.async {
            self.downloadedBytes = written
            self.totalBytes = total
            if total > 0 {
                self.progress = Double(written) / Double(total)
            }
            self.updateTimeRemaining(bytesWritten: written, bytesExpected: total)
        }
    }

    // MARK: - Delegate callbacks

    fileprivate func handleDownloadFinished(location: URL) {
        if let file = currentFolderFile {
            do {
                let staged = stagingDir.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: staged.path) {
                    try FileManager.default.removeItem(at: staged)
                }
                try FileManager.default.moveItem(at: location, to: staged)
                try? FileManager.default.removeItem(at: resumeDataURL(suffix: file.relativePath))
                folderCompletedBytes += file.size
                startNextFolderFile()
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed("Failed to save model file: \(error.localizedDescription)")
                }
            }
            return
        }

        do {
            try FileManager.default.createDirectory(at: ModelCatalog.modelDirectory, withIntermediateDirectories: true)
            let dest = ModelCatalog.path(for: model)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            try? FileManager.default.removeItem(at: resumeDataURL)
            DispatchQueue.main.async {
                self.state = .completed
                self.onFinished()
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .failed("Failed to save model: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func handleProgress(totalBytesWritten: Int64, totalBytesExpected: Int64) {
        if currentFolderFile != nil {
            reportFolderProgress(currentFileBytes: totalBytesWritten)
            return
        }
        DispatchQueue.main.async {
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpected
            if totalBytesExpected > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpected)
            } else {
                self.progress = min(1, Double(totalBytesWritten) / Double(self.model.approxBytes))
            }
            self.updateTimeRemaining(bytesWritten: totalBytesWritten, bytesExpected: totalBytesExpected)
        }
    }

    /// Must run on the main queue (reads/writes observable state).
    private func updateTimeRemaining(bytesWritten: Int64, bytesExpected: Int64) {
        guard let startTime = downloadStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let bytesDownloaded = bytesWritten - downloadStartBytes
        guard elapsed > 2, bytesDownloaded > 0 else { return }
        let bytesPerSecond = Double(bytesDownloaded) / elapsed
        let remainingBytes: Double
        if bytesExpected > 0 {
            remainingBytes = Double(bytesExpected - bytesWritten)
        } else {
            // Server didn't report size; assume the catalog's estimate
            remainingBytes = max(0, Double(model.approxBytes) - Double(bytesWritten))
        }
        estimatedTimeRemaining = formatTimeRemaining(remainingBytes / bytesPerSecond)
    }

    private func formatTimeRemaining(_ seconds: Double) -> String {
        if seconds < 60 {
            return "Less than a minute remaining"
        } else if seconds < 3600 {
            let minutes = Int(ceil(seconds / 60))
            return "About \(minutes) min remaining"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int(ceil((seconds - Double(hours * 3600)) / 60))
            return "About \(hours)h \(minutes)m remaining"
        }
    }

    fileprivate func handleError(_ error: Error) {
        // Save resume data if available
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let blob = currentResumeDataURL
            try? FileManager.default.createDirectory(
                at: blob.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? resumeData.write(to: blob)
        }
        // Don't update state for user-initiated cancellation
        if (error as? URLError)?.code != .cancelled {
            DispatchQueue.main.async {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var downloader: ModelDownloader?

    init(downloader: ModelDownloader) {
        self.downloader = downloader
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloader?.handleDownloadFinished(location: location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloader?.handleProgress(totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            downloader?.handleError(error)
        }
        // The task is finished either way (success, failure, or cancel). A
        // URLSession retains its delegate until invalidated, so without this
        // every download attempt leaked a session + delegate pair.
        session.finishTasksAndInvalidate()
    }
}
