import Foundation
import Network
import UIKit

extension RandomAccessCollection where Element: Comparable, Index == Int {
    func firstIndex(greaterThan key: Element) -> Index? {
        var lowerBound = startIndex
        var upperBound = endIndex
        while lowerBound < upperBound {
            let midIndex = lowerBound + (upperBound - lowerBound) / 2
            if self[midIndex] > key {
                upperBound = midIndex
            } else {
                lowerBound = midIndex + 1
            }
        }
        return lowerBound < endIndex ? lowerBound : nil
    }
}

/// A proxied HLS playback: its position provider plus the segment timelines parsed
/// from its media playlists, keyed by variant directory. Doubles as the
/// registration's ownership token.
final class PlaybackRegistration {
    fileprivate let key: String
    fileprivate let position: () -> TimeInterval?
    /// Called once with the upstream URL of the first media playlist seen for this playback
    fileprivate let onResolved: (URL) -> Void
    fileprivate var resolved = false
    fileprivate var timelines: [String: [Double]] = [:]

    fileprivate init(key: String, position: @escaping () -> TimeInterval?, onResolved: @escaping (URL) -> Void) {
        self.key = key
        self.position = position
        self.onResolved = onResolved
    }
}

@available(iOS 15.0, *)
public final class VideoProxyServer: @unchecked Sendable {
    public static let shared = VideoProxyServer()
    /// Session for upstream requests. Must use a serial delegate queue as per-request relay state is confined to it.
    public var session: URLSession?

    /// Keyed by the registered playlist's directory; sub-requests resolve by longest prefix. Only accessed on `queue`.
    private var registrations: [String: PlaybackRegistration] = [:]

    func registerPlayback(
        playlist url: URL,
        position: @escaping () -> TimeInterval?,
        onResolved: @escaping (URL) -> Void
    ) -> PlaybackRegistration {
        let registration = PlaybackRegistration(
            key: url.deletingLastPathComponent().path,
            position: position,
            onResolved: onResolved
        )
        queue.async { self.registrations[registration.key] = registration }
        return registration
    }

    func unregisterPlayback(_ registration: PlaybackRegistration) {
        queue.async {
            if self.registrations[registration.key] === registration {
                self.registrations.removeValue(forKey: registration.key)
            }
        }
    }

    /// Longest-prefix match of a sub-request path to its playback. Only call on `queue`.
    fileprivate func registration(forPath path: String) -> PlaybackRegistration? {
        var best: (key: String, registration: PlaybackRegistration)?
        for (key, registration) in registrations where path.hasPrefix(key) {
            if best == nil || key.count > best!.key.count {
                best = (key, registration)
            }
        }
        return best?.registration
    }

    fileprivate func storeTimeline(_ segmentEnds: [Double], forPlaylist url: URL) {
        let playlistDir = url.deletingLastPathComponent().path
        queue.async {
            guard let registration = self.registration(forPath: playlistDir) else { return }
            registration.timelines[playlistDir] = segmentEnds
            if !registration.resolved {
                registration.resolved = true
                registration.onResolved(url)
            }
        }
    }

    /// The segment containing the playback position, per the timeline of the media. Only call on `queue`.
    fileprivate func segmentHint(for url: URL) -> Int? {
        guard let registration = registration(forPath: url.path),
              let position = registration.position(),
              let ends = registration.timelines[url.deletingLastPathComponent().path], !ends.isEmpty
        else { return nil }
        if position <= 0 { return 0 }
        return ends.firstIndex(greaterThan: position) ?? ends.count - 1
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "video.proxy", qos: .userInitiated)
    private var port: UInt16 = 0
    private var activeConnections = Set<ProxyConnection>()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    public var isRunning: Bool { listener?.state == .ready }

    @objc private func onForeground() {
        guard session != nil else { return }
        try? start()
    }

    public func proxyURL(for originalURL: URL) -> URL? {
        guard session != nil, (isRunning || (try? start()) != nil) else { return nil }
        guard let scheme = originalURL.scheme, let host = originalURL.host else { return nil }
        let hostPort = originalURL.port.map { "\(host):\($0)" } ?? host
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/\(scheme)/\(hostPort)\(originalURL.path.isEmpty ? "/" : originalURL.path)"
        components.percentEncodedQuery = originalURL.query
        return components.url
    }

    private func start() throws {
        listener?.cancel()
        listener = nil

        let port = port > 0 ? NWEndpoint.Port(rawValue: port) ?? .any : .any
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let nwListener = try NWListener(using: parameters, on: port)
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        nwListener.stateUpdateHandler = { [weak self, weak nwListener] state in
            switch state {
            case .ready: self?.port = nwListener?.port?.rawValue ?? 0; semaphore.signal()
            case .failed(let e), .waiting(let e): startError = e; semaphore.signal()
            default: break
            }
        }
        nwListener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            let pc = ProxyConnection(connection: conn, server: self, queue: self.queue)
            self.activeConnections.insert(pc)
            pc.start()
        }
        listener = nwListener
        nwListener.start(queue: queue)
        semaphore.wait()
        if let error = startError { listener = nil; throw error }
    }

    fileprivate func remove(_ conn: ProxyConnection) { activeConnections.remove(conn) }

    /// Reconstructs the original URL from a proxy request target (e.g. `/https/host:port/path?q=1`).
    fileprivate func originalURL(fromRequestTarget target: String) -> URL? {
        let pathQuery = target.split(separator: "?", maxSplits: 1)
        let segments = pathQuery[0].dropFirst().split(separator: "/", maxSplits: 2)
        guard segments.count >= 2 else { return nil }
        let hostParts = segments[1].split(separator: ":", maxSplits: 1)
        var components = URLComponents()
        components.scheme = String(segments[0])
        components.host = String(hostParts[0])
        components.port = hostParts.count > 1 ? Int(hostParts[1]) : nil
        components.percentEncodedPath = segments.count > 2 ? "/\(segments[2])" : "/"
        components.percentEncodedQuery = pathQuery.count > 1 ? String(pathQuery[1]) : nil
        return components.url
    }
}

@available(iOS 15.0, *)
private final class ProxyConnection: NSObject, URLSessionDataDelegate {
    let connection: NWConnection
    private weak var server: VideoProxyServer?
    private let queue: DispatchQueue
    private var buffer = Data()
    private var currentTask: URLSessionDataTask?
    private var headersSent = false
    private var captureBuffer: Data?
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let skipHeaders: Set<String> = ["host", "connection", "proxy-connection", "keep-alive"]
    private static let extinfTagLength = 8
    private static let extinfTag: UInt64 = Array("#EXTINF:".utf8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }

    init(connection: NWConnection, server: VideoProxyServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.cleanup()
            default: break
            }
        }
        connection.start(queue: queue)
        readRequest()
    }

    private func cleanup() {
        currentTask?.cancel()
        currentTask = nil
        server?.remove(self)
    }

    private func readRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard error == nil, let data = data, !data.isEmpty else {
                return self.connection.cancel()
            }
            self.buffer.append(data)
            if self.buffer.range(of: Self.headerEnd) != nil {
                self.forwardRequest()
            } else {
                self.readRequest()
            }
        }
    }

    private func forwardRequest() {
        guard let session = server?.session else { return sendError(502) }
        guard let request = parseRequest() else { return sendError(400) }
        let task = session.dataTask(with: request)
        task.delegate = self
        currentTask = task
        headersSent = false
        task.resume()
    }

    private func parseRequest() -> URLRequest? {
        let headerBlock = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        let lines = headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestParts = lines.first?.split(separator: " ", maxSplits: 2)
        guard let requestParts, requestParts.count >= 2,
              let url = server?.originalURL(fromRequestTarget: String(requestParts[1]))
        else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = String(requestParts[0])
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !Self.skipHeaders.contains(key.lowercased()) else { continue }
            request.setValue(parts[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: key)
        }
        if url.lastPathComponent == "init.mp4", let segment = server?.segmentHint(for: url) {
            request.setValue(String(segment), forHTTPHeaderField: "x-immich-hls-msn")
        } else if url.path.hasSuffix(".m3u8"), let registration = server?.registration(forPath: url.path) {
            if let position = registration.position(), position >= 0 {
                request.setValue(String(position), forHTTPHeaderField: "x-immich-hls-pos")
            }
            // Force identity so the captured and parsed bytes are never content-encoded.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        return request
    }

    private func sendError(_ code: Int) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: code)
        let body = "\(code) \(reason)"
        let resp = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(resp.utf8), contentContext: .finalMessage, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        var head = Data(capacity: 1024)
        head.append(contentsOf: "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n".utf8)
        for (key, value) in http.allHeaderFields {
            head.append(contentsOf: "\(key): \(value)\r\n".utf8)
        }
        head.append(contentsOf: "\r\n".utf8)
        headersSent = true
        // Capture playlists to parse timelines
        if http.statusCode == 200, dataTask.originalRequest?.url?.path.hasSuffix(".m3u8") == true {
            captureBuffer = Data()
        }
        connection.send(content: head, completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        captureBuffer?.append(data)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let captured = captureBuffer, error == nil, let url = task.originalRequest?.url {
            let segmentEnds = Self.parseSegmentEnds(captured)
            if !segmentEnds.isEmpty {
                server?.storeTimeline(segmentEnds, forPlaylist: url)
            }
        }
        captureBuffer = nil
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if !headersSent { return sendError(502) }
            return connection.cancel()
        }
        currentTask = nil
        self.readRequest()
    }

    /// Cumulative segment end times from `#EXTINF:` lines.
    private static func parseSegmentEnds(_ data: Data) -> [Double] {
        var ends: [Double] = []
        ends.reserveCapacity(data.count / 24)
        var cumulative = 0.0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return } // empty Data
            var i = 0
            while i < bytes.count {
                if isExtinfLine(bytes, at: i), let duration = parseDuration(bytes, at: i + extinfTagLength) {
                    cumulative += duration
                    ends.append(cumulative)
                }
                // Skip to the next line
                guard let newline = memchr(base + i, Int32(UInt8(ascii: "\n")), bytes.count - i) else { break }
                i = UnsafeRawPointer(newline) - base + 1
            }
        }
        return ends
    }

    private static func isExtinfLine(_ bytes: UnsafeRawBufferPointer, at i: Int) -> Bool {
        i + extinfTagLength <= bytes.count && bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self) == extinfTag
    }

    /// Duration between `i` and the next `,`/line end.
    private static func parseDuration(_ bytes: UnsafeRawBufferPointer, at i: Int) -> Double? {
        var j = i
        while j < bytes.count, bytes[j] != UInt8(ascii: ","), bytes[j] != UInt8(ascii: "\n"), bytes[j] != UInt8(ascii: "\r") {
            j += 1
        }
        guard let value = Double(String(decoding: bytes[i..<j], as: UTF8.self)), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
}
