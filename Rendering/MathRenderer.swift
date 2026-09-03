import AppKit
import WebKit

/// 一次 MathJax 排版后的不可变 SVG 绘制产物。
///
/// TextKit 2 绘制回调只读取这里缓存的 `NSImage` 与度量，不执行 JavaScript，
/// 也不持有第二份可变正文。
public nonisolated final class MathRenderArtifact: NSObject, @unchecked Sendable {
    public let image: NSImage
    public let size: CGSize
    public let ascent: CGFloat
    public let descent: CGFloat

    init(image: NSImage, size: CGSize, ascent: CGFloat, descent: CGFloat) {
        self.image = image
        self.size = size
        self.ascent = ascent
        self.descent = descent
    }
}

/// 一个可缓存的 MathJax 排版请求。表达式保持用户源码原样，不做命令别名改写。
struct MathRenderRequest: Hashable, Sendable {
    let expression: String
    let display: Bool
    let fontSize: CGFloat

    var cacheKey: NSString {
        NSString(format: "%d|%.2f|%@", display ? 1 : 0, fontSize, expression)
    }
}

/// 本地 MathJax 的异步排版服务。
///
/// WebKit 与 `NSImage` 都由 MainActor 隔离。公式首次出现时异步生成 SVG 并写入
/// 有界缓存；属性应用阶段只做同步缓存查询，因此输入、选区变化与 TextKit 绘制
/// 永远不会等待 JavaScript。运行时只允许读取应用包内资源，不访问 CDN。
@MainActor
final class MathRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = MathRenderer()

    /// WebKit 脚本消息只在 MainActor 上创建、传递和解包。
    /// `Any` 本身无法声明 Sendable，因此用受 MainActor 约束的盒子标明这条边界。
    private struct BridgePayload: @unchecked Sendable {
        let values: [String: Any]
    }

    private enum RendererError: Error {
        case missingResources
        case navigationFailed
        case invalidBridgeResponse
        case invalidSVG
        case javascriptFailed(String)
    }

    private let cache = NSCache<NSString, MathRenderArtifact>()
    /// 每次真正写入新缓存产物时递增。协调器用它区分“缓存可用”与“当前 storage 已消费”。
    private(set) var artifactGeneration: UInt64 = 0
    private var invalidExpressions = Set<String>()
    private var beforeCachingArtifactHooksForTesting: [
        MathRenderRequest: @Sendable () async -> Void
    ] = [:]
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var isPageLoaded = false
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var pendingRenders: [String: CheckedContinuation<BridgePayload, Error>] = [:]
    private var renderTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var isPreparing = false
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextPreparationWaiter = 0

    private override init() {
        cache.countLimit = 512
        super.init()
    }

    func request(expression: String, display: Bool) -> MathRenderRequest {
        MathRenderRequest(
            expression: expression,
            display: display,
            fontSize: display ? Theme.blockMathFontSize : Theme.inlineMathFontSize
        )
    }

    func cachedArtifact(for request: MathRenderRequest) -> MathRenderArtifact? {
        cache.object(forKey: request.cacheKey)
    }

    /// 生成并缓存一个公式。返回 true 表示调用结束时已有可用产物，可能来自缓存命中。
    func prepare(_ request: MathRenderRequest) async -> Bool {
        if cachedArtifact(for: request) != nil { return true }
        let invalidKey = request.cacheKey as String
        if invalidExpressions.contains(invalidKey) { return false }

        // 单个 WKWebView / MathJax document 是有状态排版器。多个文档或参数化测试可能
        // 同时请求公式；在 MainActor 上排队，避免并发 tex2svgPromise 互相重入。
        await acquirePreparationSlot()
        defer { releasePreparationSlot() }
        if cachedArtifact(for: request) != nil { return true }
        guard !invalidExpressions.contains(invalidKey) else { return false }

        do {
            try Task.checkCancellation()
            try await ensurePageLoaded()
            try Task.checkCancellation()
            let artifact = try await renderWithMathJax(request)
            if let hook = beforeCachingArtifactHooksForTesting[request] {
                await hook()
            }

            // evaluateJavaScript 的 continuation 不响应 Task 取消。即使调用方在等待期间
            // 被连续输入取消，已经付出完整 WebKit 往返得到的产物也必须先进入缓存，
            // 再让取消只阻止陈旧 revision 刷新 storage。
            if cachedArtifact(for: request) == nil {
                cache.setObject(artifact, forKey: request.cacheKey)
                artifactGeneration &+= 1
            }
            try Task.checkCancellation()
            return cachedArtifact(for: request) != nil
        } catch is CancellationError {
            return cachedArtifact(for: request) != nil
        } catch RendererError.invalidBridgeResponse {
            invalidExpressions.insert(invalidKey)
            return false
        } catch RendererError.invalidSVG {
            invalidExpressions.insert(invalidKey)
            return false
        } catch {
            // WebContent 进程或资源加载失败属于可恢复故障；不负缓存，下一轮可重试。
            resetWebView()
            return false
        }
    }

    func setBeforeCachingArtifactHookForTesting(
        for request: MathRenderRequest,
        hook: (@Sendable () async -> Void)?
    ) {
        if let hook {
            beforeCachingArtifactHooksForTesting[request] = hook
        } else {
            beforeCachingArtifactHooksForTesting.removeValue(forKey: request)
        }
    }

    private func acquirePreparationSlot() async {
        guard isPreparing else {
            isPreparing = true
            return
        }
        await withCheckedContinuation { continuation in
            preparationWaiters.append(continuation)
        }
    }

    private func releasePreparationSlot() {
        guard nextPreparationWaiter < preparationWaiters.count else {
            preparationWaiters.removeAll(keepingCapacity: true)
            nextPreparationWaiter = 0
            isPreparing = false
            return
        }
        let continuation = preparationWaiters[nextPreparationWaiter]
        nextPreparationWaiter += 1
        if nextPreparationWaiter == preparationWaiters.count {
            preparationWaiters.removeAll(keepingCapacity: true)
            nextPreparationWaiter = 0
        }
        continuation.resume()
    }

    private func ensurePageLoaded() async throws {
        if isPageLoaded { return }
        try await loadPage()
        isPageLoaded = true
    }

    private func loadPage() async throws {
        _ = NSApplication.shared
        let bundle = Bundle(for: MathRenderer.self)
        guard let pageURL = bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "MathJax"
        ) else {
            throw RendererError.missingResources
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "mathResult")
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 256),
            configuration: configuration
        )
        view.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderFront(nil)
        hostWindow = window
        webView = view

        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            navigationTimeoutTask?.cancel()
            navigationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finishNavigation(.failure(RendererError.navigationFailed))
            }
            view.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }

    private func renderWithMathJax(_ request: MathRenderRequest) async throws -> MathRenderArtifact {
        guard let webView else { throw RendererError.navigationFailed }
        let identifier = UUID().uuidString
        let script = "window.museMathBridge.render(\(Self.javascriptLiteral(identifier)), \(Self.javascriptLiteral(request.expression)), \(request.display ? "true" : "false"), \(Double(request.fontSize)));"
        let payload = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<BridgePayload, Error>) in
            pendingRenders[identifier] = continuation
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.failRender(identifier: identifier, error: error)
                }
            }
            renderTimeoutTasks[identifier] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.failRender(
                    identifier: identifier,
                    error: RendererError.javascriptFailed("request timed out")
                )
            }
        }
        let result = payload.values
        guard result["error"] == nil,
              let svg = result["svg"] as? String,
              let width = Self.number(result["width"]),
              let height = Self.number(result["height"]),
              let verticalAlign = Self.number(result["verticalAlign"]),
              width.isFinite, height.isFinite, verticalAlign.isFinite,
              width > 0, height > 0
        else {
            throw RendererError.invalidBridgeResponse
        }

        guard let image = NSImage(data: Data(svg.utf8)) else {
            throw RendererError.invalidSVG
        }
        let maximumWidth = request.display
            ? Theme.blockMathMaximumWidth
            : Theme.inlineMathMaximumWidth
        let scale = min(1, maximumWidth / CGFloat(width))
        let displaySize = CGSize(
            width: max(1, CGFloat(width) * scale),
            height: max(1, CGFloat(height) * scale)
        )
        image.size = displaySize

        let unscaledDescent = max(0, -CGFloat(verticalAlign))
        let descent = min(displaySize.height, unscaledDescent * scale)
        return MathRenderArtifact(
            image: image,
            size: displaySize,
            ascent: displaySize.height - descent,
            descent: descent
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private static func javascriptLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private func finishRender(identifier: String, payload: BridgePayload) {
        guard let continuation = pendingRenders.removeValue(forKey: identifier) else { return }
        renderTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(returning: payload)
    }

    private func failRender(identifier: String, error: any Error) {
        guard let continuation = pendingRenders.removeValue(forKey: identifier) else { return }
        renderTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(throwing: error)
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func resetWebView() {
        isPageLoaded = false
        navigationContinuation?.resume(throwing: RendererError.navigationFailed)
        navigationContinuation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        for continuation in pendingRenders.values {
            continuation.resume(throwing: RendererError.navigationFailed)
        }
        pendingRenders.removeAll(keepingCapacity: false)
        for task in renderTimeoutTasks.values { task.cancel() }
        renderTimeoutTasks.removeAll(keepingCapacity: false)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mathResult")
        webView?.navigationDelegate = nil
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow?.close()
        hostWindow = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finishNavigation(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetWebView()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mathResult",
              let body = message.body as? [String: Any],
              let identifier = body["id"] as? String
        else { return }
        if let failure = body["failure"] as? String {
            let state = body["state"] as? String ?? "unknown"
            failRender(
                identifier: identifier,
                error: RendererError.javascriptFailed("\(failure) [\(state)]")
            )
            return
        }
        guard let result = body["result"] as? [String: Any] else {
            failRender(identifier: identifier, error: RendererError.invalidBridgeResponse)
            return
        }
        finishRender(identifier: identifier, payload: BridgePayload(values: result))
    }
}
