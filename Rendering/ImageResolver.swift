import AppKit

/// 图片目的地 → URL / NSImage 的解析（M5 行内图片与点击预览共用）。
public nonisolated enum ImageResolver {
    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
    }

    private final class CacheEntry {
        let image: NSImage
        let fingerprint: FileFingerprint

        init(image: NSImage, fingerprint: FileFingerprint) {
            self.image = image
            self.fingerprint = fingerprint
        }
    }

    /// NSCache 的单次操作线程安全；这里额外用锁覆盖 stat → load → stat → set
    /// 复合事务，避免较旧的并发加载最后覆盖较新的文件版本。
    private final class ImageCache: @unchecked Sendable {
        private let storage = NSCache<NSString, CacheEntry>()
        private let lock = NSLock()

        init() {
            storage.countLimit = 128
            storage.totalCostLimit = 256 * 1024 * 1024
        }

        func image(at url: URL) -> NSImage? {
            let standardizedURL = url.standardizedFileURL
            let key = standardizedURL.path as NSString
            lock.lock()
            defer { lock.unlock() }

            for _ in 0..<2 {
                guard let before = Self.fingerprint(at: standardizedURL) else {
                    storage.removeObject(forKey: key)
                    return nil
                }
                if let cached = storage.object(forKey: key), cached.fingerprint == before {
                    return cached.image
                }
                guard let image = NSImage(contentsOf: standardizedURL),
                      let after = Self.fingerprint(at: standardizedURL)
                else {
                    storage.removeObject(forKey: key)
                    return nil
                }
                guard before == after else { continue }

                storage.setObject(
                    CacheEntry(image: image, fingerprint: after),
                    forKey: key,
                    cost: Self.cost(of: image)
                )
                return image
            }

            storage.removeObject(forKey: key)
            return nil
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

    private static let cache = ImageCache()

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

    /// 同步加载本地图（带版本校验缓存）。远程图不走这里。
    public static func loadLocalImage(url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        return cache.image(at: url)
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
