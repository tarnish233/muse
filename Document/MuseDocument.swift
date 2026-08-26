import AppKit
import SwiftUI

/// NSDocument 生命周期（v0.2）：持有 EditorBuffer（唯一可变正文），
/// 序列化始终输出完整 Markdown 源码；渲染状态（AST/token/属性）都是派生数据。
final class MuseDocument: NSDocument {
    let buffer = EditorBuffer()
    let renderer = RenderCoordinator()

    override init() {
        super.init()
        buffer.textStorage.delegate = renderer
        renderer.attach(storage: buffer.textStorage)
        renderer.onTextEdited = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }
        // 新文档填入示例（打开文件时 read(from:) 会整体覆盖）。
        let full = NSRange(location: 0, length: buffer.string.utf16.count)
        buffer.textStorage.replaceCharacters(in: full, with: SampleMarkdown.text)
    }

    // 以下重写均为 nonisolated（NSDocument 的声明在主线程外也可见），
    // 文档读写由 AppKit 在主线程调度，内部用 assumeIsolated 回到 MainActor 访问 buffer。

    nonisolated override class var autosavesInPlace: Bool { true }

    nonisolated override class var readableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text", "public.text"]
    }

    nonisolated override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text", "public.text"]
    }

    // MARK: - 序列化

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        MainActor.assumeIsolated {
            let full = NSRange(location: 0, length: buffer.string.utf16.count)
            buffer.textStorage.replaceCharacters(in: full, with: text)
        }
    }

    nonisolated override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated {
            Data(buffer.textStorage.string.utf8)
        }
    }

    // MARK: - 窗口

    override func makeWindowControllers() {
        let hosting = NSHostingController(rootView: EditorShellView(document: self))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 960, height: 660))
        window.minSize = NSSize(width: 480, height: 320)
        window.title = displayName
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        addWindowController(controller)

        // 启动时填入的示例不算未保存修改。
        updateChangeCount(.changeCleared)

        window.makeKeyAndOrderFront(nil)
    }
}
