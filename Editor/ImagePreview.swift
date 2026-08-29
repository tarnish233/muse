import AppKit
import ImageIO
import MuseKit

/// 图片语法（`![标签](目的地)`）的点击预览。
///
/// 独占一行的图片已经直接呈现在正文里（见 `RenderEngine.applyImageStyle`）；
/// 这个 popover 覆盖两种它管不到的情况：夹在正文中间的图片，以及远程地址
/// （属性层只能同步解析本地图，远程图在这里异步加载）。
final class ImagePreviewController: NSViewController {
    private let destination: String
    private let baseURL: URL?
    private let imageView = NSImageView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?

    /// 预览窗的最大边长；图片按比例缩放到其中。
    private static let maxPreviewSize = NSSize(width: 420, height: 320)
    private static let maxRemoteBytes = 20 * 1024 * 1024

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

    private enum LoadResult {
        case image(NSImage, CGSize)
        case failure(String)
    }

    private static func load(destination: String, baseURL: URL?) async -> LoadResult {
        guard let url = ImageResolver.resolvedURL(destination: destination, baseURL: baseURL) else {
            return .failure("无法解析图片路径")
        }
        if url.isFileURL {
            _ = await ImageResolver.prepareLocalImage(url: url)
            guard let image = ImageResolver.cachedLocalImage(url: url) else {
                return .failure("无法加载图片")
            }
            return .image(image, image.size)
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true,
                  http.expectedContentLength <= 0
                    || http.expectedContentLength <= Int64(Self.maxRemoteBytes)
            else {
                return .failure("无法加载图片")
            }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maxRemoteBytes))
            }
            for try await byte in bytes {
                guard data.count < Self.maxRemoteBytes else {
                    return .failure("图片超过 20 MB，无法预览")
                }
                data.append(byte)
            }
            guard let image = downsampledImage(data: data) else {
                return .failure("无法加载图片")
            }
            return .image(image, image.size)
        } catch {
            return .failure("无法加载图片")
        }
    }

    private static func downsampledImage(data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxPixels = max(maxPreviewSize.width, maxPreviewSize.height) * 2
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
