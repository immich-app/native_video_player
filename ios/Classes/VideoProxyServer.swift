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
    /// Session for upstream requests. Relay state is confined to `queue`; delegate callbacks
    /// are hopped onto it, so the session's own delegate queue is not relied upon for ordering.
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

    /// In-flight upstream requests, keyed by request identity. Lets a client that reconnects
    /// (e.g. AVPlayer giving up on a slow-to-ramp transcode) reattach to the still-running
    /// request and stream from it, rather than restarting the transcode from scratch.
    /// Only accessed on `queue`.
    private var inflight: [String: UpstreamRequest] = [:]
    /// How long an upstream request is kept alive with no attached client, so an imminent
    /// reconnect can reattach (or be served from the just-completed buffer) before we give up.
    fileprivate static let upstreamGraceTTL: TimeInterval = 5.0

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

    /// Identity of a request for reattach matching: method + URL + byte range. Dynamic
    /// playback hints (position/segment) are intentionally excluded so a reconnect for the
    /// same resource reuses the in-flight request.
    fileprivate static func requestKey(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        return "\(method)\u{0}\(url)\u{0}\(range)"
    }

    /// Attaches a client to an upstream request, reusing an in-flight/just-completed one for the
    /// same key when possible, otherwise starting a fresh request. Must run on `queue`.
    fileprivate func attach(_ connection: ProxyConnection, request: URLRequest, key: String, isPlaylist: Bool) {
        if let existing = inflight[key], existing.canAttach {
            existing.attach(connection)
            return
        }
        guard let session = session else { return connection.deliverFailed() }
        let upstream = UpstreamRequest(
            key: key, request: request, isPlaylist: isPlaylist,
            server: self, session: session, queue: queue
        )
        inflight[key] = upstream
        upstream.attach(connection)
        upstream.start()
    }

    /// Drops an upstream from the in-flight map, but only if it still owns the slot (a newer
    /// request for the same key may have replaced it). Must run on `queue`.
    fileprivate func removeUpstream(_ upstream: UpstreamRequest, forKey key: String) {
        if inflight[key] === upstream { inflight.removeValue(forKey: key) }
    }

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
private final class ProxyConnection: NSObject {
    let connection: NWConnection
    private weak var server: VideoProxyServer?
    private let queue: DispatchQueue
    private var buffer = Data()
    /// The upstream request this connection is currently streaming from, if any.
    private var upstream: UpstreamRequest?
    private var headersSent = false
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let skipHeaders: Set<String> = ["host", "connection", "proxy-connection", "keep-alive"]

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
        // Detach from the upstream but leave it running: a reconnect for the same resource can
        // reattach to it instead of restarting the (real-time transcoded) request from scratch.
        upstream?.detach(self)
        upstream = nil
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
        guard let server = server else { return sendError(502) }
        guard let request = parseRequest() else { return sendError(400) }
        headersSent = false
        let key = VideoProxyServer.requestKey(request)
        let isPlaylist = request.url?.path.hasSuffix(".m3u8") ?? false
        server.attach(self, request: request, key: key, isPlaylist: isPlaylist)
    }

    // MARK: Delivery from the attached upstream (all invoked on `queue`)

    /// Binds this connection to an upstream so disconnects can orphan it for reattach.
    fileprivate func bindUpstream(_ upstream: UpstreamRequest) {
        self.upstream = upstream
    }

    fileprivate func deliverHead(_ head: Data) {
        headersSent = true
        connection.send(content: head, completion: .contentProcessed { _ in })
    }

    fileprivate func deliverBody(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Upstream finished successfully: detach and wait for the next request (keep-alive).
    fileprivate func deliverFinished() {
        upstream = nil
        readRequest()
    }

    /// Upstream failed: surface a 502 if nothing was sent yet, otherwise drop the connection.
    fileprivate func deliverFailed() {
        upstream = nil
        if !headersSent { sendError(502) } else { connection.cancel() }
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
}

/// A single upstream request whose lifetime is decoupled from the client connection that
/// triggered it. If the client disconnects (e.g. AVPlayer giving up on a slow transcode ramp-up),
/// the request keeps running and buffering; a reconnecting client for the same resource reattaches
/// and is replayed the buffered prefix before streaming live, so the transcode runs only once.
/// All state is confined to `queue`; URLSession delegate callbacks are hopped onto it.
@available(iOS 15.0, *)
private final class UpstreamRequest: NSObject, URLSessionDataDelegate {
    private let key: String
    private let request: URLRequest
    private let isPlaylist: Bool
    private weak var server: VideoProxyServer?
    private let session: URLSession
    private let queue: DispatchQueue

    private var task: URLSessionDataTask?
    /// The client currently streaming from this request, if any.
    private weak var client: ProxyConnection?
    /// Serialized HTTP response head, once the upstream responds.
    private var responseHead: Data?
    /// All body bytes received so far, for replaying to a (re)attaching client.
    private var body = Data()
    private var finished = false
    private var failed = false
    private var evictWorkItem: DispatchWorkItem?

    private static let extinfTagLength = 8
    private static let extinfTag: UInt64 = Array("#EXTINF:".utf8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }

    /// Reusable only while no client is attached and the request hasn't failed.
    var canAttach: Bool { client == nil && !failed }

    init(
        key: String, request: URLRequest, isPlaylist: Bool,
        server: VideoProxyServer, session: URLSession, queue: DispatchQueue
    ) {
        self.key = key
        self.request = request
        self.isPlaylist = isPlaylist
        self.server = server
        self.session = session
        self.queue = queue
    }

    func start() {
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        task.resume()
    }

    /// Attaches a client, replaying whatever has been buffered so far. Must run on `queue`.
    func attach(_ connection: ProxyConnection) {
        cancelEviction()
        client = connection
        connection.bindUpstream(self)
        if let head = responseHead {
            connection.deliverHead(head)
            if !body.isEmpty { connection.deliverBody(body) }
        }
        if finished {
            connection.deliverFinished()
            client = nil
            scheduleEviction()
        } else if failed {
            connection.deliverFailed()
            client = nil
            scheduleEviction()
        }
    }

    /// Detaches a disconnecting client but keeps the request alive briefly for a reconnect.
    /// Must run on `queue`.
    func detach(_ connection: ProxyConnection) {
        guard client === connection else { return }
        client = nil
        scheduleEviction()
    }

    private func scheduleEviction() {
        cancelEviction()
        let work = DispatchWorkItem { [weak self] in self?.evict() }
        evictWorkItem = work
        queue.asyncAfter(deadline: .now() + VideoProxyServer.upstreamGraceTTL, execute: work)
    }

    private func cancelEviction() {
        evictWorkItem?.cancel()
        evictWorkItem = nil
    }

    private func evict() {
        guard client == nil else { return } // a client reattached in the meantime
        task?.cancel()
        task = nil
        server?.removeUpstream(self, forKey: key)
    }

    // MARK: URLSessionDataDelegate — callbacks hop onto `queue`

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            queue.async { [weak self] in self?.handleFailure() }
            return
        }
        var head = Data(capacity: 1024)
        head.append(contentsOf: "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n".utf8)
        for (key, value) in http.allHeaderFields {
            head.append(contentsOf: "\(key): \(value)\r\n".utf8)
        }
        head.append(contentsOf: "\r\n".utf8)
        completionHandler(.allow)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.responseHead = head
            self.client?.deliverHead(head)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.body.append(data)
            self.client?.deliverBody(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let error = error {
                // Cancellation is our own eviction tearing the task down; nothing to deliver.
                if (error as NSError).code == NSURLErrorCancelled { self.task = nil; return }
                return self.handleFailure()
            }
            if self.isPlaylist {
                let segmentEnds = UpstreamRequest.parseSegmentEnds(self.body)
                if !segmentEnds.isEmpty, let url = self.request.url {
                    self.server?.storeTimeline(segmentEnds, forPlaylist: url)
                }
            }
            self.finished = true
            self.task = nil
            if let client = self.client {
                client.deliverFinished()
                self.client = nil
            }
            self.scheduleEviction()
        }
    }

    /// Marks the request failed, notifies any attached client, and schedules eviction. On `queue`.
    private func handleFailure() {
        guard !failed else { return }
        failed = true
        task = nil
        client?.deliverFailed()
        client = nil
        scheduleEviction()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
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
}
