# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目

Muse —— macOS 原生即时渲染 Markdown 编辑器（对标 Typora）。macOS 14+ · Swift 6 · AppKit（TextKit 2）+ SwiftUI · [swift-markdown `0.8.0-muse.2`](https://github.com/tarnish233/swift-markdown/releases/tag/0.8.0-muse.2)。该不可变 tag 基于上游数学语法提案，并依赖自有不可变 tag [swift-cmark `0.8.0-muse.1`](https://github.com/tarnish233/swift-cmark/releases/tag/0.8.0-muse.1)，保证依赖解析可复现。

## 命令

本机 `xcode-select` 指向 CommandLineTools，直接跑 `xcodebuild` 会报 "requires Xcode"。所有命令需前置 `DEVELOPER_DIR`（不要 `sudo xcode-select -s`）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 构建
xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Debug build

# 全量测试（Swift Testing，无 XCTest）
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'

# 单个 suite / 单个测试（suite 名 = struct 名）
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/SourceIndexTests
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  -only-testing:'MuseTests/RendererTests/renderNeverChangesCharacters()'

# 性能门槛以 Release 为准，Debug 数字只用于发现明显退化
xcodebuild test -project Muse.xcodeproj -scheme Muse -configuration Release -destination 'platform=macOS'
```

`PerformanceTests` 是 `.serialized`，跑全量时不要与其他 suite 抢 CPU。

单个测试的 ID **必须带括号**（`renderNeverChangesCharacters()`）。漏掉括号时 `xcodebuild` 会匹配 0 个测试，却依然打印 `** TEST SUCCEEDED **` —— 看 `Test run with N tests` 那行确认真的跑了。

## Target 布局

| Target | 目录 | 说明 |
|---|---|---|
| `MuseKit`（framework） | `Document/` `Parsing/` `Rendering/` | 核心逻辑，不依赖 App 层 |
| `Muse`（app） | `App/` `Editor/` | |
| `MuseTests` | `MuseTests/` + `Editor/` | |

`Editor/` 同时编进 app 和测试 target，**不在 MuseKit 里** —— 改它会同时影响两边，且测试可以直接构造 `EditorTextView`。

## 核心架构

**总不变式：只有一份可变正文。** 屏幕上就是 Markdown 源码本身；渲染=往源码上叠加 `NSAttributedString` 属性，永不改字符、永不插附件字符、永不维护第二份 `String`。`EditorBuffer`（`Document/EditorBuffer.swift`）是编辑期唯一可变正文。

数据流：

```
键入 → RenderCoordinator(NSTextStorageDelegate) → RenderPreparationWorker(actor) 后台 prepare
     → RenderEngine.applyDirty 写属性 → MuseLayoutFragment.drawDecoration 绘制块级视觉
```

**`Document/RenderCoordinator.swift`** —— 唯一的「编辑流 + 光标流」调度中心，`@MainActor`。它不解析、不算样式，只决定*何时*把*哪段*交给 engine。类注释即设计契约。
- revision 三段式：`didProcessEditing` 累积脏区 → `scheduleParse` 递增 `revision` 并**覆盖**（latest-wins，不排队）`latestParseRequest` → `runParseLoop` single-flight 消费。
- **没有 debounce timer**：用 `await Task.yield()` 合并同一 runloop 轮次；已开始的 `prepare` 不取消，靠 `applyParsed` 里 `guard rev == revision` 丢弃过期结果。
- `pendingDirtyRange` 始终维护在**当前正文的 UTF-16 坐标系**（旧 pending 穿过本次编辑重基后取并集）。它非 nil ⇒ `lastPackage` 已过期，是全局闸门：光标流、模式切换、所有表格结构操作都要求它为 nil。
- 对 storage 和 textView 都是弱引用；textView 只用来读选区和 `hasMarkedText()`。

**`Rendering/RenderEngine.swift`** —— 属性层。`prepare` 是唯一 `nonisolated`（后台跑）。`render` 整篇重写，只用于「属性全体失效」（图片缓存刷新 / 呈现模式切换 / imageBaseURL 变更）；`applyDirty` 是输入热路径，脏行扩张全靠新旧 `Package` 纯比对。`PresentationMode.source` 让所有 marker 一律 revealed，块级视觉随之消失 —— 源码模式不维护第二份字符串。

**`Rendering/BlockLayoutFragment.swift`** —— `MuseLayoutFragment`（`NSTextLayoutFragment` 子类），由 `MuseLayoutFragmentProvider` 生产。引用竖线、围栏底色、分隔线、表格格线、块图片、列表图形符号全在这里画。**块级视觉必须走 fragment，不能走 `NSTextView.draw`** —— layer-backed 的 TextKit 2 textView 上视图级绘制会被完全覆盖。

**`Parsing/`** —— `MarkdownSemantics.swift` 是**唯一**消费 swift-markdown AST 的地方，只产纯值、不碰 AppKit；marker 边界由父子 `SourceRange` 相减得到，不做分隔符匹配。`TokenScanner` 已退化成纯行索引适配器（不再维护第二套 CommonMark 匹配器）。`SourceIndex` 专解 UTF-8（cmark）↔ UTF-16（AppKit）换算；grapheme 计数不在它职责内。Token 区间一律是 **UTF-8 字节偏移**。

**`Editor/`** —— SwiftUI/AppKit 边界就是 `EditorView.swift`（`NSViewRepresentable`）。`updateNSView` **禁止回写整篇正文**，只同步呈现模式、预览 base URL、表格选区。AppKit 侧不认识 `RenderCoordinator`，只通过 `makeNSView` 注入的弱引用闭包通信（handler 返回 true = 已处理）。`EditorTextView.swift` 装配 TextKit 2 手工栈，并覆写 Enter / 表格导航 / checkbox 命中 / 拖拽。

**`Document/MuseDocument.swift`** —— `fileURL` 的 `didSet` 是把文档目录送到 `renderer.imageBaseURL` 的唯一钩子（打开、另存为、自动保存搬家都改 `fileURL`）。刻意用 `Task { @MainActor }` 而非 `assumeIsolated`：AppKit 异步保存路径不保证主线程回写。

## 属性契约

18 个 `.muse*` key 全部定义在 `Rendering/Theme.swift`，一律 `public nonisolated`（fragment 的度量路径要读）。这是渲染层与绘制层的唯一接口：

- 块级：`museBlock`（块视觉类型）、`museBlockRole`（open/close/head/delimiter，决定围栏圆角与表格末行）
- 表格：`museTableColumns` / `museTableRow` / `museTableID` / `museTableSelection` / `museTableCellSelection` / `museTableDrag*`
- 图片：`museImagePath` / `museImageSize` / `museImageDestination`
- 列表：`museListNumber` / `museListDepth` / `museListMarkerLocation` / `museListMarkerLength` / `museTaskChecked`

**绘制层禁止从源码重新解析**（例如不要自己认 `[x]`）—— swift-markdown 已接受各种 bullet/空白变体，绘制层只消费属性。`museTableSelection` 的唯一写入方是 `EditorView.Coordinator`。

## 硬约束

改渲染或编辑路径前必读。这些都是踩过的坑，代码里有对应注释。

**NSTextStorage 属性修复**
- 段落样式**必须覆盖整行含 marker 字符**：`fixParagraphStyleAttribute` 会统一同段样式，marker 若还带 base 样式，整段被修回 base，悬挂缩进/引用/标题间距全废。
- `.attachment` **只在 U+FFFC 上成立**：`endEditing → fixAttachmentAttribute` 会把它从其他字符上抹掉。这是「行内图片必须走绘制层」的根因。

**TextKit 2**
- **禁止访问 `layoutManager` / `NSLayoutManager`** —— 会不可逆地进入 TextKit 1 兼容模式。产品代码用显式 `NSTextLayoutManager` 手工栈。
- 通宽背景/围栏内边距/块图片必须先覆写 `renderingSurfaceBounds` 扩面，否则被裁掉。
- 表格分隔行不能带 `minimumLineHeight`（折叠后仍占整行高）。
- 系统选区几何会重复计入 `.kern`：表格里改用 fragment 自绘选区 + 系统选区背景设 clear。

**Swift 6 并发**
- fragment 绘制接口是 nonisolated，所以 `Theme` / `BlockVisualPalette` 是 `@unchecked Sendable`。
- **颜色不能在 fragment 内直接取动态 `NSColor.cgColor`**：绘制回调不保证 `NSAppearance.current` 正确，fragment 还会被缓存复用 —— 外观切换后会静默回落亮色。走 `BlockVisualPalette.shared` 的已解析快照。
- `NSCache` 不是 `Sendable`：用 `@unchecked Sendable` 持有者包一层讲明理由，不要用 `nonisolated(unsafe)` 关检查。

**编辑语义**
- 渲染属性全程包在 `suppressUndo` 里，不进撤销栈。
- **表格替换必须自己注册 undo**：默认 undo 会保存带渲染属性的 attributed substring，异步属性重排让它记录的区间失效。改为只记两份纯 Markdown 字符串做对称替换，且 `disableUndoRegistration` 必须在 `shouldChangeText` **之前**关掉。
- 覆写 `NSResponder` 命令入口（`insertNewline(_:)` 等），不要在 `keyDown` 里吞按键，也不要走 delegate 的 `doCommandBy`。
- **`⌃Return` 必须覆写**：原生实现插入 U+2028，cmark 不认它是换行，而文档层会原样写盘。
- 不许用手写 `isEditable` 检查代替 `shouldChangeText`（后者还覆盖 delegate 否决权）。
- 换行符归一是无条件的（存储只许有 LF），且字符串操作必须用 `.literal` —— `"\r\n"` 在 Swift 里是单个 Character，默认语义下 `contains("\r")` 对 CRLF 返回 false。
- 输入法 marked text 期间延后属性更新（协调器分开记「目标模式」和 `appliedPresentationMode`）。

**避免重复实现**
块角色与撑高行高只由显隐层独家决定；显隐只保留 `apply(_ entry:)` 一个写入入口；marker 绘制与点击命中从同一个几何函数取值（`ListMarkerGeometry`）。这三处都曾分成两份实现，后果是任一处坏掉被另一处补上、测试再也测不出问题。

## 性能门槛

200KB 文档，Release 配置：

| 路径 | 门槛 |
|---|---|
| 输入主线程预算 | P95 < 16 ms（连续输入不丢帧、不跳光标） |
| 单键「编辑 → 样式落地」 | < 150 ms |

热路径上**不要读 storage 属性**（实测 ~56µs/次），也不要按整篇 filter/sort（曾把脏行增量从 0.5ms 拖到 17.8ms，而预算是 16ms）。脏区不得随文档规模退化成整篇重绘。

## docs/ 的读法

`docs/tech-plan.md` 是**历史叙事**，按 v0.2 → v1.3 逐版追加修订说明，**后面的段落会明确推翻前面的**（例如列表几何 v1.0 的方案被 v1.2 推翻）。不要把任意单独一段当作现状。

而且文档整体会滞后于代码 —— 例如 v0.9 记的「8ms 输入 burst 去抖」在源码里已不存在。**以源码为准，文档只用来理解「为什么」。**

阶段报告：`m0-report.md` ~ `m3-report.md`、`m4-code-review.md`（审查工单）、`m0-m2-status-report.md`、`workspace-sidebar-report.md`。

M0-3 的人工验收（真实中文输入法矩阵、VoiceOver 朗读、真机 checkbox 点击）尚未回填，因此 M0 状态是「有条件通过」。涉及这三块时不要假定已验收。
