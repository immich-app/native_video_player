import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Fulfils AVPlayer resource requests through a URLSession configured for mTLS.
public final class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    public static let shared = VideoResourceLoader()
    private static let schemePrefix = "mtls-"
    private static let maxRetries = 3

    public var clientCredential: URLCredential?
    private let loaderQueue = DispatchQueue(label: "video.loader")
    private var session: URLSession!
    private var pending = [Int: PendingRequest]()
    private var taskByLoadingRequest = [ObjectIdentifier: Int]()
    private var currentHeaders = [String: String]()

    private struct PendingRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        let request: URLRequest
        let retryCount: Int
    }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 64
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = loaderQueue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    /// Creates an AVURLAsset configured to load through this resource loader.
    /// Returns nil if the loader is not active.
    public func prepareAsset(url: URL, headers: [String: String]) -> AVURLAsset? {
        guard clientCredential != nil,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme else { return nil }
        currentHeaders = headers
        components.scheme = Self.schemePrefix + scheme
        guard let customURL = components.url else { return nil }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return asset
    }

    var hasPendingRequests: Bool {
        loaderQueue.sync { !pending.isEmpty }
    }

    private func addPending(_ entry: PendingRequest) {
        pending[entry.task.taskIdentifier] = entry
        taskByLoadingRequest[ObjectIdentifier(entry.loadingRequest)] = entry.task.taskIdentifier
    }
    
    @discardableResult private func removePending(for taskId: Int) -> PendingRequest? {
        guard let entry = pending.removeValue(forKey: taskId) else { return nil }
        taskByLoadingRequest.removeValue(forKey: ObjectIdentifier(entry.loadingRequest))
        return entry
    }
    
    @discardableResult private func removePending(for loadingRequest: AVAssetResourceLoadingRequest) -> PendingRequest? {
        guard let taskId = taskByLoadingRequest.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return nil }
        return pending.removeValue(forKey: taskId)
    }

    private func originalURL(from url: URL) -> URL? {
        guard let scheme = url.scheme, scheme.hasPrefix(Self.schemePrefix) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = String(scheme.dropFirst(Self.schemePrefix.count))
        return components?.url
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let originalURL = originalURL(from: url) else { return false }

        var request = URLRequest(url: originalURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        for (key, value) in currentHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                let end = start + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        let task = session.dataTask(with: request)
        addPending(PendingRequest(loadingRequest: loadingRequest, task: task, request: request, retryCount: 0))
        task.resume()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let entry = removePending(for: loadingRequest) else { return }
        entry.task.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        defer { completionHandler(.allow) }

        guard let entry = pending[dataTask.taskIdentifier],
            let http = response as? HTTPURLResponse,
            let contentInfo = entry.loadingRequest.contentInformationRequest else { return }

        if let mimeType = http.value(forHTTPHeaderField: "Content-Type") {
            contentInfo.contentType = UTType(mimeType: mimeType)?.identifier
        }

        contentInfo.isByteRangeAccessSupported =
            http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges")?.contains("bytes") == true

        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
            let slashIndex = rangeHeader.lastIndex(of: "/"),
            let total = Int64(rangeHeader[rangeHeader.index(after: slashIndex)...]) {
            contentInfo.contentLength = total
        } else {
            contentInfo.contentLength = http.expectedContentLength
        }

        // Per https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html, we need to
        // finish the content info request immediately without responding to the 2-byte data request.
        removePending(for: dataTask.taskIdentifier)
        entry.loadingRequest.finishLoading()
        dataTask.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = pending[dataTask.taskIdentifier] else { return }
        entry.loadingRequest.dataRequest?.respond(with: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = removePending(for: task.taskIdentifier) else { return }
        guard let error = error else {
            return entry.loadingRequest.finishLoading()
        }

        if entry.retryCount >= Self.maxRetries || entry.loadingRequest.isCancelled {
            return entry.loadingRequest.finishLoading(with: error)
        }

        var retryRequest = entry.request
        if let dataRequest = entry.loadingRequest.dataRequest,
            dataRequest.currentOffset > dataRequest.requestedOffset {
            let offset = dataRequest.currentOffset
            if dataRequest.requestsAllDataToEndOfResource {
                retryRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                retryRequest.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        }
        let newTask = session.dataTask(with: retryRequest)
        addPending(PendingRequest(loadingRequest: entry.loadingRequest, task: newTask,
                                    request: retryRequest, retryCount: entry.retryCount + 1))
        newTask.resume()
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
            let clientCredential = clientCredential else {
            return completionHandler(.performDefaultHandling, nil)
        }
        completionHandler(.useCredential, clientCredential)
    }
}
