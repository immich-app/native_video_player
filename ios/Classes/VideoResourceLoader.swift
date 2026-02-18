import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Fulfils AVPlayer resource requests through a shared URLSession.
/// On iOS 15+, uses per-task delegates so auth challenges fall through to the session delegate.
/// On iOS < 15, `prepareAsset` returns nil so callers fall back to AVURLAsset with headers.
public final class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    public static let shared = VideoResourceLoader()
    private static let schemePrefix = "mtls-"
    static let maxRetries = 3

    public var sharedSession: URLSession?
    private let loaderQueue = DispatchQueue(label: "video.loader")
    private var currentHeaders = [String: String]()
    private var activeTasks = [ObjectIdentifier: URLSessionDataTask]()
    private let taskLock = NSLock()

    public var isActive: Bool {
        if #available(iOS 15.0, *) { return sharedSession != nil }
        return false
    }

    public var hasPendingRequests: Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return !activeTasks.isEmpty
    }

    public func prepareAsset(url: URL, headers: [String: String]) -> AVURLAsset? {
        guard #available(iOS 15.0, *), sharedSession != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else { return nil }
        currentHeaders = headers
        components.scheme = Self.schemePrefix + scheme
        guard let customURL = components.url else { return nil }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return asset
    }

    private func originalURL(from url: URL) -> URL? {
        guard let scheme = url.scheme, scheme.hasPrefix(Self.schemePrefix) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = String(scheme.dropFirst(Self.schemePrefix.count))
        return components?.url
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard #available(iOS 15.0, *), let session = sharedSession,
              let url = loadingRequest.request.url, let originalURL = originalURL(from: url) else { return false }

        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

        startTask(on: session, request: request, loadingRequest: loadingRequest)
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        taskLock.lock()
        let task = activeTasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
        taskLock.unlock()
        task?.cancel()
    }

    @available(iOS 15.0, *)
    fileprivate func startTask(on session: URLSession, request: URLRequest,
                               loadingRequest: AVAssetResourceLoadingRequest, retryCount: Int = 0) {
        let delegate = ResourceTaskDelegate(loadingRequest: loadingRequest, request: request,
                                            retryCount: retryCount, loader: self)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        taskLock.lock()
        activeTasks[ObjectIdentifier(loadingRequest)] = task
        taskLock.unlock()
        task.resume()
    }

    fileprivate func removeTask(for loadingRequest: AVAssetResourceLoadingRequest) {
        taskLock.lock()
        activeTasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
        taskLock.unlock()
    }
}

// MARK: - Per-Task Delegate (auth challenges intentionally omitted → session delegate handles them)

@available(iOS 15.0, *)
private class ResourceTaskDelegate: NSObject, URLSessionDataDelegate {
    let loadingRequest: AVAssetResourceLoadingRequest
    var request: URLRequest
    var retryCount: Int
    private weak var loader: VideoResourceLoader?

    init(loadingRequest: AVAssetResourceLoadingRequest, request: URLRequest,
         retryCount: Int, loader: VideoResourceLoader) {
        self.loadingRequest = loadingRequest
        self.request = request
        self.retryCount = retryCount
        self.loader = loader
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        defer { completionHandler(.allow) }
        guard let http = response as? HTTPURLResponse,
              let contentInfo = loadingRequest.contentInformationRequest else { return }

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

        // Per https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html, finish
        // the content info request immediately without responding to the 2-byte data request.
        finish()
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return finish() }
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard retryCount < VideoResourceLoader.maxRetries, !loadingRequest.isCancelled else {
            return finish(error: error)
        }

        if let dataRequest = loadingRequest.dataRequest,
           dataRequest.currentOffset > dataRequest.requestedOffset {
            let offset = dataRequest.currentOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        retryCount += 1
        guard let session = loader?.sharedSession else { return finish(error: error) }
        loader?.startTask(on: session, request: request,
                          loadingRequest: loadingRequest, retryCount: retryCount)
    }

    private func finish(error: Error? = nil) {
        loader?.removeTask(for: loadingRequest)
        guard !loadingRequest.isCancelled else { return }
        if let error = error { loadingRequest.finishLoading(with: error) }
        else { loadingRequest.finishLoading() }
    }
}
