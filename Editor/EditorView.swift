import AppKit
import SwiftUI
import MuseKit

/// SwiftUI ↔ AppKit 桥。SwiftUI 只承载结构（窗口内容/状态栏），
/// 编辑面仍是 EditorTextView；禁止在 updateNSView 中回写整篇正文。
struct EditorView: NSViewRepresentable {
    let document: MuseDocument
    let isSourceMode: Bool
    let previewBaseURL: URL?
    @AppStorage(EditorPreferences.revealCurrentBlockMarkdownKey)
    private var revealCurrentBlockMarkdown = true
    @AppStorage(EditorPreferences.clipboardCopyModeKey)
    private var clipboardCopyMode = ClipboardCopyMode.markdownSource.rawValue
    @AppStorage(EditorPreferences.copyWholeLineWhenSelectionIsEmptyKey)
    private var copyWholeLineWhenSelectionIsEmpty = false
    @AppStorage(EditorPreferences.typewriterModeKey)
    private var typewriterMode = true

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
        textView.previewBaseURL = previewBaseURL
        scrollView.documentView = textView

        textView.clipboardCopyMode = resolvedClipboardCopyMode
        textView.copiesWholeLineWhenSelectionIsEmpty = copyWholeLineWhenSelectionIsEmpty
        textView.setTypewriterMode(typewriterMode)

        textView.delegate = context.coordinator
        document.renderer.textView = textView
        document.renderer.setRevealsCurrentBlockSource(revealCurrentBlockMarkdown)
        textView.tableNavigationHandler = { [weak renderer = document.renderer] backward in
            renderer?.navigateTable(backward: backward) == true
        }
        textView.tableReturnHandler = { [weak renderer = document.renderer] in
            renderer?.insertTableRowOnReturn() == true
        }
        textView.tableArrowHandler = { [weak renderer = document.renderer] direction in
            renderer?.navigateTable(arrow: direction) == true
        }
        textView.tableSelectionArrowHandler = { [weak renderer = document.renderer] direction in
            renderer?.extendTableSelection(arrow: direction) == true
        }
        textView.tableDragHandler = { [weak renderer = document.renderer] event in
            renderer?.handleTableDrag(event) == true
        }
        textView.tableStructureActionHandler = { [weak renderer = document.renderer] tableID, action in
            renderer?.performTableAction(tableID: tableID, action: action) == true
        }
        textView.tableSelectionHandler = { [weak renderer = document.renderer] tableID, bounds in
            renderer?.selectTableCells(tableID: tableID, bounds: bounds) == true
        }
        textView.tableCopyHandler = { [weak renderer = document.renderer] pasteboard, cut in
            renderer?.copyTableSelection(to: pasteboard, cut: cut) == true
        }
        textView.tablePasteHandler = { [weak renderer = document.renderer] pasteboard in
            renderer?.pasteTableSelection(from: pasteboard) == true
        }
        textView.tableCurrentSelectionProvider = { [weak renderer = document.renderer] in
            renderer?.currentTableSelection
        }
        textView.tableDimensionProvider = { [weak renderer = document.renderer] tableID in
            renderer?.tableDimensions(tableID: tableID)
        }
        textView.viewportLocationChangeHandler = { [weak renderer = document.renderer] location in
            renderer?.updateVisibleHeading(at: location)
        }
        document.renderer.setPresentationMode(isSourceMode ? .source : .rendered)
        // 初次渲染发生在 textView 挂接之前（selection 为空），挂接后补齐显隐。
        document.renderer.refreshMarkerVisibility(into: document.buffer.textStorage)
        document.renderer.updateVisibleHeading(at: textView.visibleDocumentLocation())

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 只同步派生的呈现模式；正文仍由 NSTextStorage 独占，禁止从 SwiftUI 回写。
        document.renderer.setPresentationMode(isSourceMode ? .source : .rendered)
        // 另存为/首次保存后文档 URL 可能变化，相对路径图片的解析基准随之更新。
        if let textView = scrollView.documentView as? EditorTextView {
            textView.previewBaseURL = previewBaseURL
            textView.clipboardCopyMode = resolvedClipboardCopyMode
            textView.copiesWholeLineWhenSelectionIsEmpty = copyWholeLineWhenSelectionIsEmpty
            textView.setTypewriterMode(typewriterMode)
            document.renderer.setRevealsCurrentBlockSource(revealCurrentBlockMarkdown)
            context.coordinator.updateCustomSelection(in: textView)
        }
    }

    private var resolvedClipboardCopyMode: ClipboardCopyMode {
        ClipboardCopyMode(rawValue: clipboardCopyMode) ?? .markdownSource
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private weak var document: MuseDocument?
        private var customSelectionRange: NSRange?
        private var customSelectionAttribute: NSAttributedString.Key?

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
            if let editor = textView as? EditorTextView {
                updateCustomSelection(in: editor)
                editor.scheduleTypewriterCaretPosition()
            }
        }

        /// TextKit 2 的系统选区会把表格对齐 kern、行内公式预留 kern 重复计入。
        /// 表格继续使用专用网格几何；普通段落只要选区覆盖的段落里仍有隐藏公式，
        /// 就由 fragment 按真实 line fragment 落点绘制整段选区。
        func updateCustomSelection(in textView: EditorTextView) {
            guard let document else { return }
            let storage = document.buffer.textStorage
            let selection = textView.selectedRange()
            var attribute: NSAttributedString.Key?

            if document.renderer.presentationMode == .rendered, selection.length > 0 {
                var isTableSelection = true
                storage.enumerateAttribute(.museBlock, in: selection, options: []) { value, _, stop in
                    if value as? String != BlockVisual.table.rawValue {
                        isTableSelection = false
                        stop.pointee = true
                    }
                }
                if isTableSelection {
                    attribute = .museTableSelection
                } else {
                    let paragraphs = (storage.string as NSString).paragraphRange(for: selection)
                    var containsHiddenInlineMath = false
                    storage.enumerateAttribute(
                        .museInlineMathNoBreak,
                        in: paragraphs,
                        options: []
                    ) { value, _, stop in
                        if value != nil {
                            containsHiddenInlineMath = true
                            stop.pointee = true
                        }
                    }
                    if containsHiddenInlineMath {
                        attribute = .museTextSelection
                    }
                }
            }

            let newRange = attribute == nil ? nil : selection
            guard customSelectionRange != newRange || customSelectionAttribute != attribute else {
                textView.setUsesCustomSelection(attribute != nil)
                return
            }

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            if let oldRange = customSelectionRange,
               let oldAttribute = customSelectionAttribute,
               oldRange.location >= 0,
               oldRange.upperBound <= storage.length {
                storage.removeAttribute(oldAttribute, range: oldRange)
            }
            if let newRange, let attribute {
                storage.addAttribute(attribute, value: true, range: newRange)
            }
            undoManager?.enableUndoRegistration()
            customSelectionRange = newRange
            customSelectionAttribute = attribute
            textView.setUsesCustomSelection(attribute != nil)
            textView.needsDisplay = true
        }

        /// 点击链接：用系统浏览器打开（M2：行内链接）。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
