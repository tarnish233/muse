import AppKit

/// M1：编辑视图。手工搭建 TextKit 2 栈，把文档的单一 NSTextStorage 挂进编辑面
/// （v0.2 数据所有权边界：EditorBuffer.textStorage 是唯一可变正文）。
/// 禁止代码访问 TextKit 1 的 layoutManager（会把视图打进不可逆的兼容模式）。
final class EditorTextView: NSTextView {
    /// 块级视觉的 fragment 工厂（layoutManager.delegate 是 unowned，需强引用持有）。
    private var fragmentProvider: MuseLayoutFragmentProvider?

    static func make(textStorage: NSTextStorage) -> EditorTextView {
        // TextKit 2 标准手工栈：NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer。
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = textStorage

        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = EditorTextView(frame: .zero, textContainer: container)
        assert(textView.textLayoutManager != nil, "TextKit 2 未启用：NSTextView 未能挂接 NSTextLayoutManager")

        // 块级视觉（引用通宽背景+左竖线、代码块通宽背景、分隔线横线、列表图形符号）
        // 走自定义 fragment，不能走视图级 draw —— 见 MuseLayoutFragment 的说明。
        let provider = MuseLayoutFragmentProvider()
        textView.fragmentProvider = provider
        layoutManager.delegate = provider

        textView.allowsUndo = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true

        // 纯编辑语义：关闭所有会改写输入的自动替换/自动配对/链接检测。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // 富文本必须保留（属性渲染依赖），但不接受图片/附件（v0.2：图片 Phase 2）。
        textView.importsGraphics = false

        // 链接的绘制样式与主题一致（.link 属性默认按 linkTextAttributes 绘制）。
        textView.linkTextAttributes = [
            .foregroundColor: Theme.standard.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        textView.textContainerInset = NSSize(width: 20, height: 16)
        return textView
    }
}
