import Foundation
import Network
import UIKit

@available(iOS 15.0, *)
public final class VideoProxyServer: @unchecked Sendable {
    public static let shared = VideoProxyServer()
    public var session: URLSession?

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
        let nwListener = try NWListener(using: .tcp, on: port)
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
        connection.send(content: head, completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if !headersSent { return sendError(502) }
            return connection.cancel()
        }
        currentTask = nil
        self.readRequest()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
}
