import AppKit
import MuseKit

/// 图片语法（`![标签](目的地)`）的点击预览。
///
/// 独占一行的图片已经直接呈现在正文里（见 `RenderEngine.applyImageStyle`）；
/// 这个 popover 也覆盖夹在正文中间、不会撑高成块的图片。
final class ImagePreviewController: NSViewController {
    private let destination: String
    private let baseURL: URL?
    private let imageView = NSImageView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?

    /// 预览窗的最大边长；图片按比例缩放到其中。
    nonisolated private static let maxPreviewSize = NSSize(width: 420, height: 320)

    init(destination: String, baseURL: URL?) {
        self.destination = destination
        self.baseURL = baseURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        container.wantsLayer = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        container.addSubview(imageView)
        container.addSubview(spinner)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container

        statusLabel.stringValue = destination
        spinner.startAnimation(nil)
        loadTask = Task { [weak self] in
            let result = await Self.load(destination: self?.destination ?? "", baseURL: self?.baseURL)
            guard !Task.isCancelled, let self else { return }
            self.apply(result)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        loadTask?.cancel()
    }

    nonisolated enum LoadResult: Sendable {
        case image(NSImage, CGSize)
        case failure(String)
    }

    /// Swift 6.2 的 `NonisolatedNonsendingByDefault` 会让普通 `nonisolated async`
    /// 继续运行在调用者 actor；图片解码是 CPU 重活，因此这里需要显式 `@concurrent`
    /// 才会离开主 actor。`executionProbe` 只供回归测试观察同一生产入口的执行线程。
    @concurrent
    nonisolated static func load(
        destination: String,
        baseURL: URL?,
        executionProbe: (@Sendable (Bool) -> Void)? = nil
    ) async -> LoadResult {
        executionProbe?(isMainThreadNow())
        guard let url = ImageResolver.resolvedURL(destination: destination, baseURL: baseURL) else {
            return .failure("无法解析图片路径")
        }
        switch await ImageResolver.prepareImage(url: url) {
        case let .ready(image, _):
            return .image(image, image.size)
        case .exceedsSizeLimit:
            return .failure("图片超过 20 MB，无法预览")
        case .failure:
            return .failure("无法加载图片")
        }
    }

    /// `Thread.isMainThread` 在 async 函数体里被 Swift 6 禁用；同步小函数只用于
    /// 观察当前 executor 所落在线程，不承载任何 UI 工作。
    nonisolated private static func isMainThreadNow() -> Bool {
        Thread.isMainThread
    }

    @MainActor
    private func apply(_ result: LoadResult) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        switch result {
        case let .image(image, size):
            imageView.image = image
            let scale = min(
                Self.maxPreviewSize.width / max(size.width, 1),
                Self.maxPreviewSize.height / max(size.height, 1),
                1
            )
            let fitted = NSSize(
                width: max(120, size.width * scale),
                height: max(90, size.height * scale) + 30
            )
            // NSPopover 跟随 contentViewController 的 preferredContentSize 调整大小。
            preferredContentSize = fitted
            statusLabel.stringValue = ""
        case let .failure(message):
            statusLabel.stringValue = "\(message)：\(destination)"
        }
    }
}
