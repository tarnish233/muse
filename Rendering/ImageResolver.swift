import AppKit

/// 图片目的地 → URL / NSImage 的解析（M5 行内图片与点击预览共用）。
///
/// 行内呈现的铁律约束：只写属性、不改字符——隐藏态把 `![标签](目的地)`
/// 的首个字符换成 NSTextAttachment 呈现，字符本身仍在 storage 里。
public nonisolated enum ImageResolver {
    /// 本地图加载缓存：全量渲染对每个图片 token 都要走这里，避免重复磁盘 IO。
    ///
    /// `NSCache` 本身是线程安全的（Apple 文档：可跨线程增删查，无需自己加锁），
    /// 但它没有声明 `Sendable`，直接作为 `static let` 在 Swift 6 下不合法。
    /// 包一层 `@unchecked Sendable` 持有者，把「已知线程安全」这件事讲清楚，
    /// 而不是用 `nonisolated(unsafe)` 把检查整个关掉。
    private nonisolated final class ImageCache: @unchecked Sendable {
        let storage = NSCache<NSString, NSImage>()
    }

    private nonisolated static let cache = ImageCache()

    /// 解析目的地：http(s) 远程图、`~` 展开、相对文档目录、绝对路径。
    /// 文档无目录（未保存的示例文档）时，相对路径回退到主包资源——
    /// 示例文档自带的图片随 App 打包，开箱即可演示预览。
    public static func resolvedURL(destination: String, baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return url }
            if scheme == "file" { return url }
        }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if let base = baseURL {
            // 基准必须是「目录」语义：无尾斜杠的 file URL 会被当作文件，
            // 相对解析时丢掉最后一级目录（实测 /Users/muse/docs + assets/x.png
            // → /Users/muse/assets/x.png）。
            let directory = base.standardizedFileURL.appendingPathComponent("", isDirectory: true)
            return URL(fileURLWithPath: trimmed, relativeTo: directory)
        }
        if let bundled = Bundle.main.resourceURL {
            return URL(fileURLWithPath: trimmed, relativeTo: bundled)
        }
        return URL(fileURLWithPath: trimmed)
    }

    /// 同步加载本地图（带缓存）。远程图不走这里——属性层不接受异步写入，
    /// 远程目的地保持源码展示（点击预览走异步加载）。
    public static func loadLocalImage(url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        let key = url.standardizedFileURL.path as NSString
        if let cached = cache.storage.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: key as String),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.storage.setObject(image, forKey: key)
        return image
    }

    /// 按目的地与基准目录加载本地图。
    public static func loadLocalImage(destination: String, baseURL: URL?) -> NSImage? {
        guard let url = resolvedURL(destination: destination, baseURL: baseURL) else { return nil }
        return loadLocalImage(url: url)
    }

    /// 行内附件的显示尺寸：自然尺寸为上限，超出按 Theme.inlineImageMaxSize 缩小。
    public static func displaySize(for imageSize: NSSize) -> NSSize {
        let maxSize = Theme.inlineImageMaxSize
        guard imageSize.width > 0, imageSize.height > 0 else { return maxSize }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// 隐藏态的行内附件：目的地可解析且为本地图时返回，否则 nil（保持源码呈现）。
    public static func inlineAttachment(destination: String, baseURL: URL?) -> NSTextAttachment? {
        guard let image = loadLocalImage(destination: destination, baseURL: baseURL) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: displaySize(for: image.size))
        return attachment
    }
}
