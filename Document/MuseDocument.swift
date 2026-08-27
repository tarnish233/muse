import AppKit

/// NSDocument 生命周期（v0.2）：持有 EditorBuffer（唯一可变正文），
/// 序列化始终输出完整 Markdown 源码；渲染状态（AST/token/属性）都是派生数据。
@MainActor
public final class MuseDocument: NSDocument {
    /// App 层注入窗口外壳，避免 MuseKit 反向依赖 SwiftUI 编辑器视图。
    public static var windowControllerFactory: ((MuseDocument) -> NSWindowController)?

    public let buffer = EditorBuffer()
    public let renderer = RenderCoordinator()
    private var isReadingContent = false

    public override init() {
        super.init()
        buffer.textStorage.delegate = renderer
        renderer.attach(storage: buffer.textStorage)
        renderer.onTextEdited = { [weak self] in
            guard let self, !self.isReadingContent else { return }
            self.updateChangeCount(.changeDone)
        }
        // 新文档填入示例（打开文件时 read(from:) 会整体覆盖）。
        let full = NSRange(location: 0, length: buffer.string.utf16.count)
        buffer.textStorage.replaceCharacters(in: full, with: SampleMarkdown.text)
    }

    // 以下重写均为 nonisolated（NSDocument 的声明在主线程外也可见），
    // 文档读写由 AppKit 在主线程调度，内部用 assumeIsolated 回到 MainActor 访问 buffer。

    nonisolated public override class var autosavesInPlace: Bool { true }

    nonisolated public override class var readableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text", "public.text"]
    }

    nonisolated public override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text", "public.text"]
    }

    // MARK: - 序列化

    nonisolated public override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        MainActor.assumeIsolated {
            isReadingContent = true
            defer {
                isReadingContent = false
                updateChangeCount(.changeCleared)
            }
            let full = NSRange(location: 0, length: buffer.string.utf16.count)
            buffer.textStorage.replaceCharacters(in: full, with: text)
        }
    }

    nonisolated public override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated {
            Data(buffer.textStorage.string.utf8)
        }
    }

    // MARK: - 窗口

    public override func makeWindowControllers() {
        guard let factory = Self.windowControllerFactory else {
            // MuseKit 也可在无 UI 宿主中使用（例如序列化/性能测试）。
            // App 宿主通过 windowControllerFactory 注入实际 SwiftUI 外壳。
            updateChangeCount(.changeCleared)
            return
        }

        addWindowController(factory(self))

        // 启动时填入的示例不算未保存修改。
        updateChangeCount(.changeCleared)
    }
}
