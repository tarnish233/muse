import AppKit
import ImageIO

/// 已经完成解码和缩放、可由 TextKit 属性强持有的图片绘制产物。
///
/// `NSCache` 只负责跨渲染复用；正文当前正在显示的像素必须跟随属性生命周期，不能因
/// 系统内存压力驱逐缓存后突然退回占位框。对象不可变，绘制回调只读取。
public nonisolated final class ImageRenderArtifact: NSObject, @unchecked Sendable {
    public let image: NSImage
    public let url: URL
    public let displaySize: CGSize

    init(image: NSImage, url: URL, displaySize: CGSize) {
        self.image = image
        self.url = url
        self.displaySize = displaySize
    }
}

/// 图片目的地 → URL / NSImage 的解析（M5 行内图片与点击预览共用）。
public nonisolated enum ImageResolver {
    struct RemoteDownload: Sendable {
        let fileURL: URL
        let response: URLResponse
    }

    enum RemoteDownloadError: Error, Equatable {
        case exceedsSizeLimit
        case missingResponse
    }

    typealias RemoteDownloader = @Sendable (URL) async throws -> RemoteDownload
    typealias RetrySleeper = @Sendable (Duration) async throws -> Void

    public enum PreparationResult: Sendable {
        case ready(NSImage, cacheChanged: Bool)
        case exceedsSizeLimit
        /// 资源当前不可用；`cacheChanged` 为 true 表示旧的本地缓存刚被淘汰，正文
        /// 必须刷新为占位尺寸，不能继续保留陈旧图片与行高。
        case unavailable(cacheChanged: Bool)

        public var cacheChanged: Bool {
            switch self {
            case let .ready(_, cacheChanged), let .unavailable(cacheChanged):
                cacheChanged
            case .exceedsSizeLimit:
                false
            }
        }
    }

    public static let maxRemoteBytes = 20 * 1024 * 1024
    private static let remoteRetryDelays: [Duration] = [
        .milliseconds(250),
        .seconds(1),
    ]

    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
    }

    private final class CacheEntry {
        let image: NSImage
        let fingerprint: FileFingerprint?

        init(image: NSImage, fingerprint: FileFingerprint?) {
            self.image = image
            self.fingerprint = fingerprint
        }
    }

    private final class ImageCache: @unchecked Sendable {
        private let storage = NSCache<NSString, CacheEntry>()

        init() {
            storage.countLimit = 128
            storage.totalCostLimit = 256 * 1024 * 1024
        }

        func cachedImage(at url: URL) -> NSImage? {
            storage.object(forKey: Self.key(for: url))?.image
        }

        func removeImage(at url: URL) {
            storage.removeObject(forKey: Self.key(for: url))
        }

        /// 刷新磁盘版本，返回内存缓存是否发生变化。调用方负责把它放在后台执行；
        /// NSCache 自身线程安全，因此磁盘 I/O 与解码不需要占用全局锁。
        @discardableResult
        func refresh(at url: URL) -> Bool {
            let standardizedURL = url.standardizedFileURL
            let key = Self.key(for: standardizedURL)

            for _ in 0..<2 {
                guard let before = Self.fingerprint(at: standardizedURL) else {
                    let changed = storage.object(forKey: key) != nil
                    storage.removeObject(forKey: key)
                    return changed
                }
                if let cached = storage.object(forKey: key), cached.fingerprint == before {
                    return false
                }
                guard let image = NSImage(contentsOf: standardizedURL),
                      let after = Self.fingerprint(at: standardizedURL)
                else {
                    let changed = storage.object(forKey: key) != nil
                    storage.removeObject(forKey: key)
                    return changed
                }
                guard before == after else { continue }

                storage.setObject(
                    CacheEntry(image: image, fingerprint: after),
                    forKey: key,
                    cost: Self.cost(of: image)
                )
                return true
            }

            let changed = storage.object(forKey: key) != nil
            storage.removeObject(forKey: key)
            return changed
        }

        /// 远程资源由 URLSession/HTTP 缓存负责新鲜度；这里仅保存已经通过类型、
        /// 大小与解码校验的图片，供布局和绘制热路径同步读取。
        func storeRemoteImage(_ image: NSImage, at url: URL) -> Bool {
            let key = Self.key(for: url)
            guard storage.object(forKey: key) == nil else { return false }
            storage.setObject(
                CacheEntry(image: image, fingerprint: nil),
                forKey: key,
                cost: Self.cost(of: image)
            )
            return true
        }

        private static func key(for url: URL) -> NSString {
            ImageResolver.normalizedURL(url).absoluteString as NSString
        }

        private static func fingerprint(at url: URL) -> FileFingerprint? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else { return nil }
            return FileFingerprint(
                size: size.uint64Value,
                modificationDate: attributes[.modificationDate] as? Date,
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            )
        }

        private static func cost(of image: NSImage) -> Int {
            let pixels = image.representations.map { representation in
                max(1, representation.pixelsWide) * max(1, representation.pixelsHigh)
            }.max() ?? max(1, Int(image.size.width * image.size.height))
            let (cost, overflow) = pixels.multipliedReportingOverflow(by: 4)
            return overflow ? Int.max : cost
        }
    }

    /// URLSession data task 的落盘接收器。每个数据块在写入前检查剩余额度，因此未知
    /// Content-Length / chunked 响应也不可能先把任意体积写满磁盘再被拒绝。
    final class RemoteDataAccumulator {
        let fileURL: URL
        let maxBytes: Int64
        private(set) var bytesWritten: Int64 = 0
        private var fileHandle: FileHandle?
        private var ownsFile = true

        init(
            maxBytes: Int,
            temporaryDirectory: URL = FileManager.default.temporaryDirectory
        ) throws {
            self.maxBytes = Int64(max(0, maxBytes))
            fileURL = temporaryDirectory.appending(
                path: "MuseRemoteImage-\(UUID().uuidString).tmp"
            )
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                fileHandle = try FileHandle(forWritingTo: fileURL)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }

        func append(_ data: Data) throws {
            let chunkBytes = Int64(data.count)
            guard chunkBytes <= maxBytes - bytesWritten else {
                throw RemoteDownloadError.exceedsSizeLimit
            }
            guard let fileHandle else { throw CocoaError(.fileWriteUnknown) }
            try fileHandle.write(contentsOf: data)
            bytesWritten += chunkBytes
        }

        /// 关闭文件并把删除责任转交给调用方。
        func finish() throws -> URL {
            if let fileHandle {
                try fileHandle.close()
                self.fileHandle = nil
            }
            ownsFile = false
            return fileURL
        }

        func discard() {
            if let fileHandle {
                try? fileHandle.close()
                self.fileHandle = nil
            }
            guard ownsFile else { return }
            ownsFile = false
            try? FileManager.default.removeItem(at: fileURL)
        }

        deinit {
            discard()
        }
    }

    private final class RemoteDownloadCancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var operation: RemoteDownloadOperation?
        private var cancellationRequested = false

        func store(_ operation: RemoteDownloadOperation) {
            let shouldCancel = lock.withLock {
                self.operation = operation
                return cancellationRequested
            }
            if shouldCancel { operation.cancel() }
        }

        func cancel() {
            let operation = lock.withLock {
                cancellationRequested = true
                return self.operation
            }
            operation?.cancel()
        }
    }

    /// 每个请求使用独立串行 delegate queue，把 URLSession 的分块回调直接写入有界
    /// 临时文件。异步调用者取消时同步取消 data task，最终完成回调统一清理或移交文件。
    private final class RemoteDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int64
        private let accumulator: RemoteDataAccumulator
        private let continuation: CheckedContinuation<RemoteDownload, Error>
        private let cancellationLock = NSLock()
        private var cancellationRequested = false
        private var response: URLResponse?
        private var terminalError: Error?
        private var completed = false
        private var task: URLSessionDataTask?
        private var session: URLSession?

        init(
            maxBytes: Int,
            continuation: CheckedContinuation<RemoteDownload, Error>
        ) throws {
            self.maxBytes = Int64(max(0, maxBytes))
            accumulator = try RemoteDataAccumulator(maxBytes: maxBytes)
            self.continuation = continuation
        }

        func start(url: URL) {
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.qualityOfService = .utility
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .useProtocolCachePolicy
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            self.session = session
            let task = session.dataTask(with: url)
            let shouldCancel = cancellationLock.withLock {
                self.task = task
                return cancellationRequested
            }
            // 先 resume 再 cancel，保证即使调用者在 operation 建立前已经取消，
            // URLSession 也会进入 didCompleteWithError，checked continuation 必定收口。
            task.resume()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            let task = cancellationLock.withLock {
                cancellationRequested = true
                return self.task
            }
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            self.response = response
            if response.expectedContentLength > maxBytes {
                terminalError = RemoteDownloadError.exceedsSizeLimit
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            guard terminalError == nil else { return }
            do {
                try accumulator.append(data)
            } catch {
                terminalError = error
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard completed == false else { return }
            completed = true
            defer {
                cancellationLock.withLock { self.task = nil }
                self.session = nil
                session.finishTasksAndInvalidate()
            }

            if let terminalError {
                accumulator.discard()
                continuation.resume(throwing: terminalError)
                return
            }
            if cancellationLock.withLock({ cancellationRequested }) {
                accumulator.discard()
                continuation.resume(throwing: CancellationError())
                return
            }
            if let error {
                accumulator.discard()
                continuation.resume(throwing: error)
                return
            }
            guard let response else {
                accumulator.discard()
                continuation.resume(throwing: RemoteDownloadError.missingResponse)
                return
            }

            do {
                let fileURL = try accumulator.finish()
                continuation.resume(returning: RemoteDownload(fileURL: fileURL, response: response))
            } catch {
                accumulator.discard()
                continuation.resume(throwing: error)
            }
        }
    }

    private actor ImageLoadWorker {
        private let cache: ImageCache

        init(cache: ImageCache) {
            self.cache = cache
        }

        func prepare(_ url: URL) -> Bool {
            cache.refresh(at: url)
        }
    }

    private static let cache = ImageCache()
    private static let loadWorker = ImageLoadWorker(cache: cache)

    static func normalizedURL(_ url: URL) -> URL {
        url.isFileURL ? url.standardizedFileURL : url.absoluteURL
    }

    @concurrent
    private static func downloadRemoteImage(from url: URL) async throws -> RemoteDownload {
        let cancellationBox = RemoteDownloadCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let operation = try RemoteDownloadOperation(
                        maxBytes: maxRemoteBytes,
                        continuation: continuation
                    )
                    cancellationBox.store(operation)
                    operation.start(url: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    /// 解析目的地：http(s) 远程图、`~` 展开、相对文档目录、绝对路径。
    /// 本地路径只做一次 percent decode；无效 escape 保守按字面路径处理。
    public static func resolvedURL(destination: String, baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "file" { return url }
        }

        let localPath = trimmed.removingPercentEncoding ?? trimmed
        if localPath.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
        }
        if let base = baseURL {
            let directory = base.standardizedFileURL.appendingPathComponent("", isDirectory: true)
            return URL(fileURLWithPath: localPath, relativeTo: directory)
        }
        if let bundled = Bundle.main.resourceURL {
            return URL(fileURLWithPath: localPath, relativeTo: bundled)
        }
        return URL(fileURLWithPath: localPath)
    }

    /// 仅查询内存缓存；渲染和绘制热路径使用它，不触发磁盘或网络 I/O。
    public static func cachedImage(url: URL) -> NSImage? {
        cache.cachedImage(at: url)
    }

    static func removeCachedImageForTesting(url: URL) {
        cache.removeImage(at: url)
    }

    /// 仅查询内存缓存；渲染和绘制热路径必须使用它，不能访问磁盘。
    public static func cachedLocalImage(url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        return cachedImage(url: url)
    }

    /// 在后台 actor 上检查文件版本并准备图片；返回缓存是否发生变化。
    @discardableResult
    public static func prepareLocalImage(url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        return await loadWorker.prepare(url.standardizedFileURL)
    }

    /// 在正文图片显示前准备缓存。本地图片走文件指纹刷新；HTTP(S) 图片在并发
    /// executor 上下载到 URLSession 临时文件并降采样，完成后由协调器触发一次
    /// 纯属性重排。临时文件避免未知 Content-Length 响应先占满进程内存。
    @concurrent
    public static func prepareImage(url: URL) async -> PreparationResult {
        await prepareImage(
            url: url,
            remoteDownloader: { try await downloadRemoteImage(from: $0) },
            retrySleeper: { try await Task.sleep(for: $0) }
        )
    }

    /// 确定性测试入口：生产与测试共用完整的 HTTP 校验、重试、大小限制、解码和缓存路径。
    @concurrent
    static func prepareImage(
        url: URL,
        remoteDownloader: @escaping RemoteDownloader,
        retrySleeper: @escaping RetrySleeper
    ) async -> PreparationResult {
        if url.isFileURL {
            let changed = await prepareLocalImage(url: url)
            guard let image = cachedImage(url: url) else {
                return .unavailable(cacheChanged: changed)
            }
            return .ready(image, cacheChanged: changed)
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unavailable(cacheChanged: false)
        }
        if let image = cachedImage(url: url) {
            return .ready(image, cacheChanged: false)
        }

        for attempt in 0...remoteRetryDelays.count {
            do {
                try Task.checkCancellation()
                let download = try await remoteDownloader(url)
                defer { try? FileManager.default.removeItem(at: download.fileURL) }
                guard let http = download.response as? HTTPURLResponse else {
                    return .unavailable(cacheChanged: false)
                }
                guard (200..<300).contains(http.statusCode) else {
                    guard attempt < remoteRetryDelays.count,
                          shouldRetry(statusCode: http.statusCode),
                          await waitBeforeRetry(
                            remoteRetryDelays[attempt],
                            using: retrySleeper
                          )
                    else { return .unavailable(cacheChanged: false) }
                    continue
                }
                guard http.mimeType?.lowercased().hasPrefix("image/") == true else {
                    return .unavailable(cacheChanged: false)
                }
                try Task.checkCancellation()
                guard let downloadedSize = downloadedFileSize(at: download.fileURL) else {
                    return .unavailable(cacheChanged: false)
                }
                guard remotePayloadExceedsLimit(
                    expectedContentLength: http.expectedContentLength,
                    downloadedFileSize: downloadedSize
                ) == false else { return .exceedsSizeLimit }
                guard let image = downsampledRemoteImage(fileURL: download.fileURL) else {
                    return .unavailable(cacheChanged: false)
                }
                let changed = cache.storeRemoteImage(image, at: url)
                return .ready(image, cacheChanged: changed)
            } catch RemoteDownloadError.exceedsSizeLimit {
                return .exceedsSizeLimit
            } catch is CancellationError {
                return .unavailable(cacheChanged: false)
            } catch {
                guard Task.isCancelled == false,
                      attempt < remoteRetryDelays.count,
                      shouldRetry(error: error),
                      await waitBeforeRetry(
                        remoteRetryDelays[attempt],
                        using: retrySleeper
                      )
                else { return .unavailable(cacheChanged: false) }
            }
        }
        return .unavailable(cacheChanged: false)
    }

    public static func prepareImage(destination: String, baseURL: URL?) async -> PreparationResult {
        guard let url = resolvedURL(destination: destination, baseURL: baseURL) else {
            return .unavailable(cacheChanged: false)
        }
        return await prepareImage(url: url)
    }

    /// 网络层与正文渲染之间的确定性测试缝：生产下载也经过同一解码和缓存入口。
    @discardableResult
    static func cacheRemoteImageData(_ data: Data, at url: URL) -> Bool {
        guard !url.isFileURL,
              let image = downsampledRemoteImage(data: data)
        else { return false }
        return cache.storeRemoteImage(image, at: url)
    }

    static func remotePayloadExceedsLimit(
        expectedContentLength: Int64,
        downloadedFileSize: Int64,
        maxBytes: Int = ImageResolver.maxRemoteBytes
    ) -> Bool {
        let limit = Int64(max(0, maxBytes))
        return expectedContentLength > limit || downloadedFileSize > limit
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private static func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func waitBeforeRetry(
        _ delay: Duration,
        using retrySleeper: RetrySleeper
    ) async -> Bool {
        do {
            try await retrySleeper(delay)
            try Task.checkCancellation()
            return true
        } catch {
            return false
        }
    }

    private static func downloadedFileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private static func downsampledRemoteImage(fileURL: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return downsampledRemoteImage(source: source)
    }

    private static func downsampledRemoteImage(data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampledRemoteImage(source: source)
    }

    private static func downsampledRemoteImage(source: CGImageSource) -> NSImage? {
        let maxPixels = max(Theme.inlineImageMaxSize.width, Theme.inlineImageMaxSize.height) * 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }

    /// 阻塞式加载仅保留给非 UI 工具和兼容调用；正文排版、绘制与预览均不走这里。
    public static func loadLocalImage(url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        cache.refresh(at: url)
        return cachedImage(url: url)
    }

    public static func loadLocalImage(destination: String, baseURL: URL?) -> NSImage? {
        guard let url = resolvedURL(destination: destination, baseURL: baseURL) else { return nil }
        return loadLocalImage(url: url)
    }

    public static func displaySize(for imageSize: NSSize) -> NSSize {
        let maxSize = Theme.inlineImageMaxSize
        guard imageSize.width > 0, imageSize.height > 0 else { return maxSize }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    public static func inlineAttachment(destination: String, baseURL: URL?) -> NSTextAttachment? {
        guard let image = loadLocalImage(destination: destination, baseURL: baseURL) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: displaySize(for: image.size))
        return attachment
    }
}
