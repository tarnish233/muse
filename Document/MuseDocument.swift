import AppKit

/// NSDocument 生命周期（v0.2）：持有 EditorBuffer（唯一可变正文），
/// 序列化始终输出完整 Markdown 源码；渲染状态（AST/token/属性）都是派生数据。
@MainActor
public final class MuseDocument: NSDocument {
    /// App 层注入窗口外壳，避免 MuseKit 反向依赖 SwiftUI 编辑器视图。
    public static var windowControllerFactory: ((MuseDocument) -> NSWindowController)?

    public let buffer = EditorBuffer()
    public let renderer = RenderCoordinator()
    public let location = DocumentLocationState()
    private var isReadingContent = false

    public override init() {
        super.init()
        synchronizeLocation()
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

    /// 相对路径图片的解析基准（文档所在目录）。
    ///
    /// 图片的呈现尺寸决定行高，属于**属性**，所以基准必须在渲染时就在手上——
    /// 不能留给绘制层临时解析。未保存的文档没有目录，`ImageResolver` 会退回主包
    /// 资源，示例文档自带的图因此开箱可见。
    ///
    /// 挂在 `fileURL` 上而不是 `read(from:)` 里：打开、另存为、自动保存搬家都会
    /// 改 `fileURL`，这是唯一覆盖全部路径的那一处。跳一次 MainActor 而不用
    /// `assumeIsolated`——AppKit 的异步保存路径不保证在主线程回写，宁可晚一轮，
    /// 不要冒断言崩溃的风险。
    nonisolated public override var fileURL: URL? {
        didSet {
            let capturedURL = fileURL?.standardizedFileURL
            Task { @MainActor [weak self] in
                guard let self,
                      self.fileURL?.standardizedFileURL == capturedURL
                else { return }
                self.synchronizeLocation()
            }
        }
    }

    /// Synchronizes every location-dependent consumer from NSDocument.fileURL.
    /// AppKit window adoption calls this before installing a new SwiftUI root.
    public func synchronizeLocation() {
        let standardizedURL = fileURL?.standardizedFileURL
        location.update(fileURL: standardizedURL, displayName: displayName)
        renderer.imageBaseURL = standardizedURL?.deletingLastPathComponent()
    }

    // 以下重写均为 nonisolated（NSDocument 的声明在主线程外也可见），
    // 文档读写由 AppKit 在主线程调度，内部用 assumeIsolated 回到 MainActor 访问 buffer。

    nonisolated public override class var autosavesInPlace: Bool { true }

    nonisolated public override class var readableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    nonisolated public override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    // MARK: - 序列化

    /// 文件使用的行终止符。
    ///
    /// 正文在 `NSTextStorage` 里一律归一成 LF，写回时还原成这里记下的值：编辑层
    /// （列表续行、`SourceIndex` 的 UTF-8↔UTF-16 映射、marker 范围）因此只需要认
    /// 一种终止符，而 Windows 协作者的 CRLF 文件保存后字节不变。
    ///
    /// 代价是**混合终止符的文件会被统一**成主流的那一种——保真度换编辑层的简单。
    /// CotEditor 选的是相反的路（存储保留原样、在插入边界转换），代价是每个
    /// `NSRange` 计算都要处理「CRLF 是 2 个 UTF-16 单元且不可切开」，对这个
    /// 逐标量建索引的代码库来说改动面太大。
    public nonisolated enum LineEnding: Character, CaseIterable, Sendable {
        case lf = "\n"
        case cr = "\r"
        case crlf = "\r\n"

        public var string: String { String(rawValue) }
    }

    private var lineEnding = LineEnding.lf

    private nonisolated enum FileEncoding: Sendable {
        case utf8
        case utf8WithBOM
        case utf16LittleEndian
        case utf16BigEndian

        static func decode(_ data: Data) -> (text: String, encoding: FileEncoding)? {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                return String(data: data.dropFirst(3), encoding: .utf8).map { ($0, .utf8WithBOM) }
            }
            if data.starts(with: [0xFF, 0xFE]) {
                let body = data.dropFirst(2)
                guard body.count.isMultiple(of: 2) else { return nil }
                return String(data: body, encoding: .utf16LittleEndian)
                    .map { ($0, .utf16LittleEndian) }
            }
            if data.starts(with: [0xFE, 0xFF]) {
                let body = data.dropFirst(2)
                guard body.count.isMultiple(of: 2) else { return nil }
                return String(data: body, encoding: .utf16BigEndian)
                    .map { ($0, .utf16BigEndian) }
            }
            return String(data: data, encoding: .utf8).map { ($0, .utf8) }
        }

        func encode(_ text: String) -> Data? {
            switch self {
            case .utf8:
                return Data(text.utf8)
            case .utf8WithBOM:
                return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
            case .utf16LittleEndian:
                guard let body = text.data(using: .utf16LittleEndian, allowLossyConversion: false) else {
                    return nil
                }
                return Data([0xFF, 0xFE]) + body
            case .utf16BigEndian:
                guard let body = text.data(using: .utf16BigEndian, allowLossyConversion: false) else {
                    return nil
                }
                return Data([0xFE, 0xFF]) + body
            }
        }
    }

    private var fileEncoding = FileEncoding.utf8

    /// 全文扫描出每个行终止符，按出现次数取主流的那一种；平票时取最早出现的。
    ///
    /// 分行用 Foundation 的 `.byLines`——它对 LF/CR/CRLF/NEL/LS/PS 都是正确的；
    /// 只有「这一处用的是哪种」需要自己按 UTF-16 code unit 判定，Foundation 没有
    /// 对应的 API。
    nonisolated static func dominantLineEnding(in text: String) -> LineEnding {
        let string = text as NSString
        guard string.length > 0 else { return .lf }
        var counts: [LineEnding: Int] = [:]
        var firstIndex: [LineEnding: Int] = [:]

        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, enclosingRange, _ in
            let start = NSMaxRange(substringRange)
            guard start < NSMaxRange(enclosingRange) else { return }
            let ending: LineEnding
            switch string.character(at: start) {
            case 0x0A:
                ending = .lf
            case 0x0D:
                ending = NSMaxRange(enclosingRange) - start > 1
                    && string.character(at: start + 1) == 0x0A ? .crlf : .cr
            default:
                return // NEL / LS / PS 不是 CommonMark 的换行，不参与投票
            }
            counts[ending, default: 0] += 1
            if firstIndex[ending] == nil { firstIndex[ending] = start }
        }

        guard let winner = counts.max(by: { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : (firstIndex[lhs.key] ?? 0) > (firstIndex[rhs.key] ?? 0)
        }) else { return .lf }
        return winner.key
    }

    nonisolated public override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = FileEncoding.decode(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let text = decoded.text
        let ending = Self.dominantLineEnding(in: text)
        // 归一是无条件的：存储必须只有 LF，哪怕主流终止符本来就是 LF——混合文件
        // 里那几处 CRLF 同样要被抹平，否则编辑层会遇到它不认识的终止符。
        //
        // 全部走 `.literal`（按 UTF-16 code unit 匹配）而不是默认的字符簇比较：
        // `"\r\n"` 在 Swift 里是**单个** Character，默认语义下 `contains("\r")`
        // 对 CRLF 文本是 false，`replacingOccurrences(of: "\n")` 也匹配不到
        // CRLF 里的那个 LF。
        let body = text.utf16.contains(0x0D)
            ? text
                .replacingOccurrences(of: LineEnding.crlf.string, with: LineEnding.lf.string, options: .literal)
                .replacingOccurrences(of: LineEnding.cr.string, with: LineEnding.lf.string, options: .literal)
            : text
        MainActor.assumeIsolated {
            isReadingContent = true
            defer {
                isReadingContent = false
                updateChangeCount(.changeCleared)
            }
            lineEnding = ending
            fileEncoding = decoded.encoding
            let full = NSRange(location: 0, length: buffer.string.utf16.count)
            buffer.textStorage.replaceCharacters(in: full, with: body)
        }
    }

    nonisolated public override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            let body = buffer.textStorage.string
            let restored = lineEnding == .lf ? body : body.replacingOccurrences(
                of: LineEnding.lf.string,
                with: lineEnding.string,
                options: .literal
            )
            guard let data = fileEncoding.encode(restored) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return data
        }
    }

    // MARK: - 窗口

    private func clearInitialSampleChangeCountIfNeeded() {
        guard fileURL == nil, autosavedContentsFileURL == nil else { return }
        updateChangeCount(.changeCleared)
    }

    public override func makeWindowControllers() {
        guard let factory = Self.windowControllerFactory else {
            // MuseKit 也可在无 UI 宿主中使用（例如序列化/性能测试）。
            // App 宿主通过 windowControllerFactory 注入实际 SwiftUI 外壳。
            clearInitialSampleChangeCountIfNeeded()
            return
        }

        addWindowController(factory(self))

        // 启动时填入的示例不算未保存修改。
        clearInitialSampleChangeCountIfNeeded()
    }
}
