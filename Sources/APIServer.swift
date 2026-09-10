import Foundation
import Observation
import Darwin
import FlyingFox
import FlyingSocks

/// A local, OpenAI-compatible HTTP server that exposes the on-device whisper.cpp
/// engine so other apps can use this Mac as a drop-in replacement for OpenAI's
/// audio transcription API.
///
/// Endpoints:
///   - `POST /v1/audio/transcriptions`  (multipart/form-data: `file`, optional `model`,
///     `language`, `response_format` = json | verbose_json | text | srt | vtt)
///   - `POST /v1/audio/translations`    (same, but translates the audio to English)
///   - `GET  /v1/models`
///
/// It reuses the app's single `TranscriptionService` (injected via `attach`) so the
/// model is loaded once and all requests serialize on the existing whisper queue.
@Observable
@MainActor
final class APIServer {
    static let shared = APIServer()

    // UserDefaults keys (kept in sync with @AppStorage in SettingsView).
    static let enabledKey = "apiServerEnabled"
    static let portKey = "apiServerPort"
    static let tokenKey = "apiServerToken"
    static let allowLANKey = "apiServerAllowLAN"
    /// When true, each request and its outcome are logged to stderr (run log).
    /// Off by default; flip on to diagnose client issues.
    static let verboseLogKey = "apiServerVerboseLogging"
    static let defaultPort: UInt16 = 8080
    /// Per-connection timeout for the HTTP server. Generous so long transcriptions
    /// aren't severed mid-flight (FlyingFox defaults to a 15s timeout).
    static let connectionTimeout: TimeInterval = 3600

    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Address clients should use while running, e.g. "http://127.0.0.1:8080". Nil when stopped.
    private(set) var baseURL: String?

    /// Injected by `AppState` so the server reuses the app's single loaded model.
    private var service: TranscriptionService?

    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?

    /// Bonjour/DNS-SD advertisement (only while LAN access is enabled).
    private var netService: NetService?
    private let bonjourDelegate = BonjourDelegate()

    private init() {}

    static var configuredPort: UInt16 {
        let v = UserDefaults.standard.integer(forKey: portKey)
        return (v >= 1 && v <= 65535) ? UInt16(v) : defaultPort
    }

    /// Called once by `AppState` after it creates the shared `TranscriptionService`.
    func attach(service: TranscriptionService) {
        self.service = service
    }

    func start() {
        guard !isRunning else { return }
        guard let service else {
            lastError = "Transcription service is not ready yet."
            return
        }

        let port = Self.configuredPort
        let allowLAN = UserDefaults.standard.bool(forKey: Self.allowLANKey)

        isRunning = true
        lastError = nil
        baseURL = "http://\(allowLAN ? Self.localIPAddress() : "127.0.0.1"):\(port)"

        // Advertise on the local network only when LAN access is on — a 127.0.0.1
        // binding isn't reachable by the devices that would discover it.
        if allowLAN { publishBonjour(port: port) }

        let api = OpenAITranscriptionAPI(service: service)
        runTask = Task.detached { [weak self] in
            do {
                // FlyingFox's default connection timeout is 15s, which severs the
                // client mid-transcription for anything but very short clips (the
                // handler finishes and logs 200, but the client already got a 500).
                // Allow long transcriptions to complete.
                let server: HTTPServer
                if allowLAN {
                    server = HTTPServer(port: port, timeout: Self.connectionTimeout)  // 0.0.0.0 — all interfaces
                } else {
                    server = HTTPServer(address: try sockaddr_in.inet(ip4: "127.0.0.1", port: port),
                                        timeout: Self.connectionTimeout)
                }
                await api.register(on: server)
                await self?.setServer(server)
                try await server.run()
                await self?.markStopped(error: nil)               // returned after stop()
            } catch {
                await self?.markStopped(error: "Couldn't start server on port \(port): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        baseURL = nil
        stopBonjour()
        let s = server
        server = nil
        runTask?.cancel()
        runTask = nil
        Task.detached { await s?.stop(timeout: 1) }
    }

    private func setServer(_ s: HTTPServer) { self.server = s }

    private func markStopped(error: String?) {
        isRunning = false
        baseURL = nil
        server = nil
        stopBonjour()
        if let error {
            lastError = error
            // Reflect the failure back to the toggle so the UI doesn't show "on".
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        }
    }

    // MARK: - Bonjour advertisement

    /// Publish a DNS-SD service (`_whisperasr._tcp`) so clients on the LAN can
    /// discover this server without knowing its IP. TXT records carry the API path
    /// (`/v1`), app version, and whether a bearer token is required.
    private func publishBonjour(port: UInt16) {
        let macName = Host.current().localizedName ?? "Mac"
        let service = NetService(domain: "local.", type: "_whisperasr._tcp.",
                                 name: "WhisperASR on \(macName)", port: Int32(port))
        var txt: [String: Data] = ["path": Data("/v1".utf8)]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            txt["version"] = Data(version.utf8)
        }
        let token = UserDefaults.standard.string(forKey: Self.tokenKey)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        txt["auth"] = Data((token.isEmpty ? "none" : "bearer").utf8)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = bonjourDelegate
        service.publish()
        netService = service
    }

    private func stopBonjour() {
        netService?.stop()
        netService = nil
    }

    /// Best-effort LAN IPv4 of the primary interface, for display in Settings.
    static func localIPAddress() -> String {
        var address = "0.0.0.0"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                           &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }
}

// MARK: - Bonjour delegate

/// Logs Bonjour publish results to the (gated) run log; retained by `APIServer`.
private final class BonjourDelegate: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        OpenAITranscriptionAPI.log("bonjour: published '\(sender.name)' \(sender.type) on port \(sender.port)")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        OpenAITranscriptionAPI.log("bonjour: publish FAILED \(errorDict)")
    }
}

// MARK: - OpenAI-compatible request handlers

/// Stateless, `Sendable` request handlers. Holds only the `Sendable` transcription
/// service and reads config from `UserDefaults` per request, so handlers run freely
/// off the main actor.
private struct OpenAITranscriptionAPI: Sendable {
    let service: TranscriptionService

    /// Uploads larger than this are rejected with 413. The whole body is held in
    /// memory during multipart parsing (~2-3x the file size transiently), so an
    /// unbounded upload from a LAN client could exhaust RAM. 1 GB covers hours
    /// of audio in any common format.
    static let maxUploadBytes = 1_000_000_000

    func register(on server: HTTPServer) async {
        await server.appendRoute("/v1/audio/transcriptions", for: [.POST]) { req in
            await self.handleTranscription(req, translate: false)
        }
        await server.appendRoute("/v1/audio/translations", for: [.POST]) { req in
            await self.handleTranscription(req, translate: true)
        }
        await server.appendRoute("/v1/models", for: [.GET]) { req in
            self.handleModels(req)
        }
    }

    // MARK: Transcription / translation

    func handleTranscription(_ request: HTTPRequest, translate: Bool) async -> HTTPResponse {
        let kind = translate ? "translations" : "transcriptions"
        if let denied = Self.checkAuth(request) {
            Self.log("\(kind): rejected (auth)")
            return denied
        }

        let contentTypeHeader = request.headers[.contentType] ?? "(none)"
        Self.log("\(kind): request content-type=\(contentTypeHeader)")

        guard let contentType = request.headers[.contentType],
              contentType.lowercased().contains("multipart/form-data"),
              let boundary = MultipartParser.boundary(from: contentType) else {
            Self.log("\(kind): 400 not multipart/form-data")
            return Self.errorResponse(.badRequest,
                "Request must be multipart/form-data with an audio 'file'.")
        }

        // Reject oversized uploads up front when the client declares a length…
        if let declared = request.headers[.contentLength].flatMap(Int.init),
           declared > Self.maxUploadBytes {
            Self.log("\(kind): 413 declared content-length \(declared)B exceeds cap")
            return Self.errorResponse(.payloadTooLarge,
                "Upload too large (\(declared) bytes); the limit is \(Self.maxUploadBytes) bytes.")
        }

        let body: Data
        do {
            body = try await request.bodyData
        } catch {
            Self.log("\(kind): 400 couldn't read body: \(error.localizedDescription)")
            return Self.errorResponse(.badRequest, "Could not read request body.")
        }

        // …and re-check after reading for chunked requests without one.
        guard body.count <= Self.maxUploadBytes else {
            Self.log("\(kind): 413 body \(body.count)B exceeds cap")
            return Self.errorResponse(.payloadTooLarge,
                "Upload too large (\(body.count) bytes); the limit is \(Self.maxUploadBytes) bytes.")
        }

        let parts = MultipartParser.parse(body: body, boundary: boundary)
        Self.log("\(kind): body=\(body.count)B parts=[\(parts.map { $0.name }.joined(separator: ","))]")
        guard let filePart = parts.first(where: { $0.name == "file" }), !filePart.data.isEmpty else {
            Self.log("\(kind): 400 missing/empty 'file' part")
            return Self.errorResponse(.badRequest, "Missing required 'file' field.")
        }

        let responseFormat = (parts.first { $0.name == "response_format" }?.text ?? "json").lowercased()
        let langRaw = parts.first { $0.name == "language" }?.text
        let language = (langRaw?.isEmpty == false) ? langRaw : nil

        // Stage the upload to a temp file (AVAssetReader needs a real file URL).
        let ext = Self.fileExtension(filename: filePart.filename, contentType: filePart.contentType)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperasr-\(UUID().uuidString)\(ext)")
        Self.log("\(kind): file='\(filePart.filename ?? "?")' type=\(filePart.contentType ?? "?") "
            + "size=\(filePart.data.count)B -> \(tmp.lastPathComponent) format=\(responseFormat)")
        do {
            try filePart.data.write(to: tmp)
        } catch {
            Self.log("\(kind): 500 couldn't stage upload: \(error.localizedDescription)")
            return Self.errorResponse(.internalServerError, "Could not stage upload.", type: "server_error")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let start = Date()
        Self.log("\(kind): transcribe START")
        do {
            let result = try await service.transcribe(
                fileURL: tmp, language: language, translate: translate) { _ in }
            let secs = Date().timeIntervalSince(start)
            Self.log(String(format: "%@: 200 ok (%d chars, %d segments) in %.1fs",
                            kind, result.text.count, result.segments.count, secs))
            return Self.formatResult(result, format: responseFormat, translate: translate)
        } catch TranscriptionExecutionError.busy {
            return Self.errorResponse(.serviceUnavailable, "Transcription service is busy; retry after the current operation finishes.", type: "server_error")
        } catch TranscriptionExecutionError.queuedTimedOut {
            return Self.errorResponse(.serviceUnavailable, "Transcription queue wait timed out; retry after the current operation finishes.", type: "server_error")
        } catch TranscriptionExecutionError.timedOut {
            return Self.errorResponse(.gatewayTimeout, "Transcription timed out.", type: "server_error")
        } catch {
            let secs = Date().timeIntervalSince(start)
            Self.log(String(format: "%@: 500 transcribe failed after %.1fs: %@",
                            kind, secs, error.localizedDescription))
            return Self.errorResponse(.internalServerError, error.localizedDescription, type: "server_error")
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Write a timestamped diagnostic line to stderr (captured in the run log) when
    /// verbose logging is enabled. Unbuffered, so lines appear immediately even when
    /// stdout is redirected to a file. The flag is read per call, so it toggles live.
    static func log(_ message: String) {
        guard UserDefaults.standard.bool(forKey: APIServer.verboseLogKey) else { return }
        let ts = logTimeFormatter.string(from: Date())
        FileHandle.standardError.write(Data("[APIServer \(ts)] \(message)\n".utf8))
    }

    // MARK: Models

    func handleModels(_ request: HTTPRequest) -> HTTPResponse {
        if let denied = Self.checkAuth(request) { return denied }
        var ids = ["whisper-1"]
        if let selected = UserDefaults.standard.string(forKey: "selectedModelFile"),
           !selected.isEmpty {
            ids.append(selected)
        }
        return Self.jsonResponse(.ok, ModelsList(data: ids.map { ModelsList.Model(id: $0) }))
    }

    // MARK: Auth

    /// Returns a 401 response when an API key is configured and the request's
    /// `Authorization: Bearer <key>` doesn't match; nil when access is allowed.
    static func checkAuth(_ request: HTTPRequest) -> HTTPResponse? {
        let token = UserDefaults.standard.string(forKey: APIServer.tokenKey)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !token.isEmpty else { return nil }
        let provided = request.headers[.authorization] ?? ""
        guard provided == "Bearer \(token)" else {
            return errorResponse(.unauthorized, "Invalid or missing API key.")
        }
        return nil
    }

    // MARK: Response formatting

    static func formatResult(_ result: TranscriptionResult, format: String, translate: Bool) -> HTTPResponse {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case "text":
            return textResponse(text)
        case "srt":
            return textResponse(makeSRT(result.segments), contentType: "application/x-subrip")
        case "vtt":
            return textResponse(makeVTT(result.segments), contentType: "text/vtt; charset=utf-8")
        case "verbose_json":
            let duration = result.segments.last?.end ?? 0
            let segs = result.segments.enumerated().map { index, s in
                VerboseSegment(
                    id: index, seek: 0, start: s.start, end: s.end ?? s.start,
                    text: s.text.trimmingCharacters(in: .whitespaces),
                    tokens: [], temperature: 0, avg_logprob: 0,
                    compression_ratio: 0, no_speech_prob: 0)
            }
            let verbose = VerboseTranscription(
                task: translate ? "translate" : "transcribe",
                language: result.detectedLanguage ?? "",
                duration: duration, text: text, segments: segs)
            return jsonResponse(.ok, verbose)
        default: // "json"
            return jsonResponse(.ok, JSONTranscription(text: text))
        }
    }

    static func jsonResponse<T: Encodable>(_ status: HTTPStatusCode, _ value: T) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(statusCode: status,
                            headers: [.contentType: "application/json; charset=utf-8"],
                            body: data)
    }

    static func textResponse(_ text: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(statusCode: .ok, headers: [.contentType: contentType], body: Data(text.utf8))
    }

    static func errorResponse(_ status: HTTPStatusCode, _ message: String,
                              type: String = "invalid_request_error") -> HTTPResponse {
        jsonResponse(status, APIError(error: .init(message: message, type: type, code: nil)))
    }

    // MARK: Subtitles

    static func makeSRT(_ segments: [TranscriptionSegment]) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            let line = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(i + 1)\n"
            out += "\(srtTime(seg.start)) --> \(srtTime(seg.end ?? seg.start))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    static func makeVTT(_ segments: [TranscriptionSegment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            let line = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(vttTime(seg.start)) --> \(vttTime(seg.end ?? seg.start))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    private static func clockParts(_ t: Double) -> (h: Int, m: Int, s: Int, ms: Int) {
        let total = Int((max(0, t) * 1000).rounded())
        return (total / 3_600_000, (total % 3_600_000) / 60_000, (total % 60_000) / 1000, total % 1000)
    }

    static func srtTime(_ t: Double) -> String {
        let p = clockParts(t)
        return String(format: "%02d:%02d:%02d,%03d", p.h, p.m, p.s, p.ms)
    }

    static func vttTime(_ t: Double) -> String {
        let p = clockParts(t)
        return String(format: "%02d:%02d:%02d.%03d", p.h, p.m, p.s, p.ms)
    }

    // MARK: Upload extension inference

    static func fileExtension(filename: String?, contentType: String?) -> String {
        if let filename {
            let ext = (filename as NSString).pathExtension
            if !ext.isEmpty { return "." + ext }
        }
        let ct = (contentType ?? "").lowercased()
        if ct.contains("wav") { return ".wav" }
        if ct.contains("mpeg") || ct.contains("mp3") { return ".mp3" }
        if ct.contains("mp4") || ct.contains("m4a") || ct.contains("aac") { return ".m4a" }
        if ct.contains("ogg") { return ".ogg" }
        if ct.contains("flac") { return ".flac" }
        if ct.contains("webm") { return ".webm" }
        return ".wav"
    }
}

// MARK: - OpenAI JSON shapes

private struct JSONTranscription: Encodable {
    let text: String
}

private struct VerboseSegment: Encodable {
    let id: Int
    let seek: Int
    let start: Double
    let end: Double
    let text: String
    let tokens: [Int]
    let temperature: Double
    let avg_logprob: Double
    let compression_ratio: Double
    let no_speech_prob: Double
}

private struct VerboseTranscription: Encodable {
    let task: String
    let language: String
    let duration: Double
    let text: String
    let segments: [VerboseSegment]
}

private struct ModelsList: Encodable {
    struct Model: Encodable {
        let id: String
        let object = "model"
        let created = 0
        let owned_by = "whisperasr"
    }
    let object = "list"
    let data: [Model]
}

private struct APIError: Encodable {
    struct Detail: Encodable {
        let message: String
        let type: String
        let code: String?
    }
    let error: Detail
}

// MARK: - Multipart/form-data parsing

struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
    /// The part's body decoded as a trimmed UTF-8 string (for simple form fields).
    var text: String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MultipartParser {
    /// Extract the boundary token from a `multipart/form-data; boundary=...` header.
    static func boundary(from contentType: String) -> String? {
        guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var b = String(contentType[r.upperBound...])
        if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
        b = b.trimmingCharacters(in: .whitespaces)
        if b.count >= 2, b.hasPrefix("\""), b.hasSuffix("\"") {
            b = String(b.dropFirst().dropLast())
        }
        return b.isEmpty ? nil : b
    }

    static func parse(body: Data, boundary: String) -> [MultipartPart] {
        let dashBoundary = Data("--\(boundary)".utf8)
        let crlf = Data([0x0D, 0x0A])
        let headerSep = Data([0x0D, 0x0A, 0x0D, 0x0A])

        let delimiters = body.allRanges(of: dashBoundary)
        guard delimiters.count >= 2 else { return [] }

        var parts: [MultipartPart] = []
        for i in 0..<(delimiters.count - 1) {
            let segStart = delimiters[i].upperBound
            let segEnd = delimiters[i + 1].lowerBound
            guard segStart <= segEnd else { continue }

            var segment = body.subdata(in: segStart..<segEnd)
            // The closing delimiter is "--boundary--"; its trailing "--" lands here — skip it.
            if segment.starts(with: [0x2D, 0x2D]) { continue }
            if segment.starts(with: crlf) { segment.removeFirst(2) }
            if segment.count >= 2, segment.suffix(2).elementsEqual(crlf) { segment.removeLast(2) }

            guard let sep = segment.range(of: headerSep) else { continue }
            let headerData = segment.subdata(in: segment.startIndex..<sep.lowerBound)
            let contentData = segment.subdata(in: sep.upperBound..<segment.endIndex)

            let headers = parseHeaders(headerData)
            guard let disposition = headers["content-disposition"],
                  let name = paramValue(in: disposition, key: "name") else { continue }
            let filename = paramValue(in: disposition, key: "filename")
            parts.append(MultipartPart(
                name: name, filename: filename,
                contentType: headers["content-type"], data: contentData))
        }
        return parts
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        guard let str = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in str.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    /// Read a `key="value"` (or `key=value`) parameter from a header line. Matches only
    /// when `key` isn't part of a longer token (so "name" won't match "filename").
    private static func paramValue(in header: String, key: String) -> String? {
        let needle = key + "="
        var searchStart = header.startIndex
        while let r = header.range(of: needle, options: .caseInsensitive,
                                   range: searchStart..<header.endIndex) {
            let boundaryOK: Bool
            if r.lowerBound == header.startIndex {
                boundaryOK = true
            } else {
                let before = header[header.index(before: r.lowerBound)]
                boundaryOK = !before.isLetter && before != "-"
            }
            if boundaryOK {
                var rest = header[r.upperBound...]
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
                    return String(rest)
                }
                if let semi = rest.firstIndex(of: ";") {
                    return String(rest[..<semi]).trimmingCharacters(in: .whitespaces)
                }
                return String(rest).trimmingCharacters(in: .whitespaces)
            }
            searchStart = r.upperBound
        }
        return nil
    }
}

private extension Data {
    /// All non-overlapping ranges where `pattern` occurs.
    func allRanges(of pattern: Data) -> [Range<Int>] {
        guard !pattern.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = startIndex
        while start < endIndex, let r = range(of: pattern, options: [], in: start..<endIndex) {
            ranges.append(r)
            start = r.upperBound
        }
        return ranges
    }
}
