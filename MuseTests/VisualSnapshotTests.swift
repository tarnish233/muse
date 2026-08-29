import AppKit
import Testing
@testable import MuseKit

/// 离屏视觉快照：把真实 TextKit 2 视图路径的渲染结果成像为 PNG，
/// 供排版观感复查（对应 tech-plan「渲染与绘制」验收：真机窗口可见性）。
/// 产物写入 /tmp/muse-snapshot-light.png；同时断言成像非空白，
/// 防止「测试全绿、真机全白」的假绿复发。
///
/// 只做浅色成像：离屏 `dataWithPDF` 不经窗口，动态色/块调色板的暗色解析
/// 与真实窗口路径不一致（会回落亮色），暗色回归由
/// `blockVisualsFollowAppearance` / `paletteUpdatesOnAppearanceChange`
/// 的像素与调色板断言覆盖，最终观感以 App 内切换系统外观为准。
@Suite @MainActor struct VisualSnapshotTests {
    /// 示例文档里的图片随 App 打包（`App/sample-image.png`）。测试宿主的
    /// `Bundle.main` 是 xctest，解析不到它，所以直接按源码位置指到仓库里的
    /// 那一份——成像要覆盖「图片真的画出来了」，不能让它退化成占位框。
    static let sampleAssetDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MuseTests/
        .deletingLastPathComponent()   // 仓库根
        .appendingPathComponent("App")

    @Test func renderSampleDocumentToSnapshot() throws {
        let storage = NSTextStorage(string: SampleMarkdown.text)
        let textView = EditorTextView.make(textStorage: storage)
        let width: CGFloat = 900
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)

        let engine = RenderEngine()
        _ = engine.render(
            package: engine.prepare(SampleMarkdown.text),
            selection: nil,
            into: storage,
            imageBaseURL: Self.sampleAssetDirectory
        )
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // 画布跟随实测排版高度：块图片会把文档撑高好几百点，写死高度会把
        // 文末的内容裁到画布外，成像里看不到反而以为渲染丢了。
        let height = (layoutManager.usageBoundsForTextContainer.height + 64).rounded(.up)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // 浅色成像（对标 Typora github.css 基准主题），不依赖测试宿主的系统外观。
        textView.appearance = NSAppearance(named: .aqua)

        // 真实视图绘制路径：PDF 捕获后转位图（sourceOver 保留底色）。
        let pdfData = textView.dataWithPDF(inside: NSRect(x: 0, y: 0, width: width, height: height))
        let pdfImage = try #require(NSImage(data: pdfData))
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        pdfImage.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(x: 0, y: 0, width: pdfImage.size.width, height: pdfImage.size.height),
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        // 非空白断言：与主色差值 > 40 的抽样像素须超过 1%（字形 + 块视觉）。
        guard let data = rep.bitmapData else {
            Issue.record("bitmap data unavailable")
            return
        }
        let bytesPerPixel = rep.bitsPerPixel / 8
        let bytesPerRow = rep.bytesPerRow
        func gray(at row: Int, _ column: Int) -> Int {
            let offset = row * bytesPerRow + column * bytesPerPixel
            return (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3
        }
        var buckets: [Int: Int] = [:]
        var sampled = 0
        for row in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for column in stride(from: 0, to: rep.pixelsWide, by: 4) {
                buckets[gray(at: row, column) / 32, default: 0] += 1
                sampled += 1
            }
        }
        let dominantGray = (buckets.max { $0.value < $1.value }?.key ?? 0) * 32 + 16
        var contrastPixels = 0
        for row in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for column in stride(from: 0, to: rep.pixelsWide, by: 4)
            where abs(gray(at: row, column) - dominantGray) > 40 {
                contrastPixels += 1
            }
        }
        #expect(Double(contrastPixels) / Double(max(sampled, 1)) > 0.01,
                "snapshot looks blank: \(contrastPixels)/\(sampled), dominant gray \(dominantGray)")

        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/muse-snapshot-light.png"))
    }
}
