import AppKit
import SwiftUI

/// SwiftUI ↔ AppKit 桥。SwiftUI 只承载结构（窗口内容/状态栏），
/// 编辑面仍是 EditorTextView；禁止在 updateNSView 中回写整篇正文。
struct EditorView: NSViewRepresentable {
    let document: MuseDocument

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
        // 初次渲染发生在 textView 挂接之前（selection 为空），挂接后补齐显隐。
        document.renderer.refreshMarkerVisibility(into: document.buffer.textStorage)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // M1：无状态回写。渲染由 textStorage 编辑回调驱动。
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
            document.renderer.updateMarkerVisibility(
                selection: textView.selectedRange(),
                into: document.buffer.textStorage
            )
        }
    }
}
