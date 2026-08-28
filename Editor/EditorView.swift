import AppKit
import SwiftUI
import MuseKit

/// SwiftUI ↔ AppKit 桥。SwiftUI 只承载结构（窗口内容/状态栏），
/// 编辑面仍是 EditorTextView；禁止在 updateNSView 中回写整篇正文。
struct EditorView: NSViewRepresentable {
    let document: MuseDocument
    let isSourceMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = EditorTextView.make(textStorage: document.buffer.textStorage)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        document.renderer.textView = textView
        document.renderer.setPresentationMode(isSourceMode ? .source : .rendered)
        // 初次渲染发生在 textView 挂接之前（selection 为空），挂接后补齐显隐。
        document.renderer.refreshMarkerVisibility(into: document.buffer.textStorage)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 只同步派生的呈现模式；正文仍由 NSTextStorage 独占，禁止从 SwiftUI 回写。
        document.renderer.setPresentationMode(isSourceMode ? .source : .rendered)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private weak var document: MuseDocument?

        init(document: MuseDocument) {
            self.document = document
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let document else { return }
            guard let textView = notification.object as? NSTextView else { return }
            guard !textView.hasMarkedText() else { return } // 组合输入期间不做显隐更新
            document.renderer.refreshPresentationMode()
            document.renderer.updateMarkerVisibility(
                selection: textView.selectedRange(),
                into: document.buffer.textStorage
            )
        }

        /// 点击链接：用系统浏览器打开（M2：行内链接）。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
