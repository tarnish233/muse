# Muse 技术方案

一款极简即时渲染 Markdown 编辑器（对标 Typora），纯 macOS 原生实现。

- 版本：v0.2 · 2026-08-26
- 目标平台：macOS 14+
- 技术栈：Swift 6 · AppKit（TextKit 2）· SwiftUI · swift-markdown

---

## 01 结论

**技术路线保持不变：使用 AppKit 的 `NSTextView`（TextKit 2）作为编辑核心，SwiftUI 作为应用外壳，swift-markdown 负责 Markdown 语义解析。**

但实现必须遵守以下边界：

1. `NSTextStorage` 是编辑期唯一可变文本；`NSDocument` 只负责持有编辑缓冲区、序列化和文档生命周期，不能再维护第二份可变 `String`。
2. 保存内容始终是完整 Markdown 源码。渲染属性、AST、token、图片和主题都是可丢弃、可重建的派生状态。
3. swift-markdown 负责语义 AST；单独的轻量 `MarkdownTokenScanner` 负责精确定位 `**`、反引号、列表前缀和链接标记等源码 token。
4. 使用 `SourceIndex` 显式完成 swift-markdown 的 UTF-8 行列位置与 `NSTextStorage` 的 UTF-16 `NSRange` 之间的转换。
5. 标记隐藏采用“源码字符不删除 + 光标处回显”，但零宽布局、IME、选区、换行和辅助功能必须先通过 M0 原型验证，不能把它当成已经成立的前提。
6. undo/redo 只记录源码修改；渲染属性不进入撤销栈，文本撤销后重新计算渲染结果。
7. MVP 先使用整篇解析，但必须在后台处理不可变快照并带 revision；是否支持 200KB 文档以及是否需要增量解析，以基准测试结果决定。

**工作量预期：**可演示 MVP 约 6～8 周全职；达到可长期日用的稳定程度约 8～12 周。M0 技术验证是开工门槛，若标记隐藏方案不能通过验收，应立即调整交互或布局实现，而不是在 M3 后返工。

## 02 方案对比

| 方案 | 手感 / 输入法 | 开发量 | 结论 |
|---|---|---|---|
| A · 原生 `NSTextView` + TextKit 2 | 系统原生编辑、IME、滚动和辅助功能基础最好 | 编辑语义、token 定位和布局行为需要自研 | ✅ 推荐（选定） |
| B · 原生壳 + `WKWebView` + CodeMirror 6 / Milkdown | 开发快，但输入、字体与系统服务隔着 WebKit | 数周可形成可用原型 | ⚠️ M0 失败时的备选 |
| C · 纯 SwiftUI `TextEditor` | 只能满足纯文本编辑，无法承担即时富文本布局 | 表面简单，但无法实现目标体验 | ❌ 排除 |

补充约束：

- 明确使用 `NSTextView(usingTextLayoutManager: true)` 创建编辑器，并在代码审查中禁止访问 TextKit 1 的 `layoutManager`，避免不可逆地进入兼容模式。
- SwiftUI 只承载窗口内容、侧栏、工具栏、设置与状态展示；不要让 `updateNSView` 持续把整篇字符串回写给 `NSTextView`。
- 文档采用 AppKit `NSDocument` 生命周期：`MuseDocument` 持有 `EditorBuffer`，窗口内容通过 `NSWindowController` / `NSHostingController` 或 `NSHostingView` 组合 SwiftUI 与 AppKit。
- 自定义引用条、零宽 marker、图片等涉及布局的能力，必要时使用 `NSTextLayoutFragment`，但不在未经验证时写成 MVP 的既定实现。
- SPM 依赖暂时只有 `swift-markdown`；不依赖其未公开或不存在的增量解析 API。

## 03 总体架构

```text
┌──────────────────────────────────────────────────────┐
│ AppKit 文档生命周期                                  │
│ MuseDocument → EditorBuffer → NSTextStorage          │
│                    唯一可变文本                       │
├──────────────────────────────────────────────────────┤
│ SwiftUI 外壳                                         │
│ 窗口内容 · 侧栏 · 工具栏 · 设置 · 状态               │
├──────────────────────────────────────────────────────┤
│ EditorTextView（NSTextView + TextKit 2）              │
│ 原生输入 · 选区 · 滚动 · 查找 · 拼写检查 · undo       │
├──────────────────────────────────────────────────────┤
│ Render Pipeline                                      │
│ String Snapshot + revision                           │
│   ├─ SourceIndex：UTF-8 SourceRange → UTF-16 NSRange │
│   ├─ swift-markdown：语义 AST                         │
│   └─ MarkdownTokenScanner：精确源码 token             │
│                    ↓                                 │
│ RenderSnapshot(revision, spans, markers, blocks)     │
│                    ↓ 仅接受最新 revision             │
│ 主线程批量应用派生属性                                │
└──────────────────────────────────────────────────────┘
```

### 数据所有权

- `EditorBuffer.textStorage`：编辑期唯一真相，所有键入、粘贴和行为命令都修改它。
- `MuseDocument`：拥有 `EditorBuffer`，从 `textStorage.string` 生成保存快照，处理 open/save/autosave 和文档 undo manager。
- `RenderSnapshot`：纯值类型派生数据，可以随时丢弃重建；不负责保存，也不进入 undo。
- SwiftUI 状态：只保存文件名、主题、侧栏可见性等 UI 状态，不复制正文。

### 两条更新流

**编辑流：**

```text
textDidChange
→ revision + 1
→ 捕获不可变 String 快照
→ 后台解析 AST、token 和区间索引
→ 生成 RenderSnapshot
→ MainActor 检查 revision
→ 批量应用最新渲染结果
```

旧 revision 的解析结果直接丢弃。编辑线程不能等待整篇解析完成。

**光标流：**

```text
selectionDidChange
→ 查询当前 RenderSnapshot
→ 找到相交 inline span 与所在 block
→ 只更新受影响 marker 的可见状态
```

光标移动不触发重新解析。若当前输入仍处于 marked text，跳过会影响 marked range 的渲染更新。

### 目录结构

```text
muse/
├─ Muse.xcodeproj
├─ App/
│  ├─ AppDelegate.swift
│  └─ AppShellView.swift
├─ Document/
│  ├─ MuseDocument.swift
│  └─ EditorBuffer.swift          # 持有唯一 NSTextStorage
├─ Editor/
│  ├─ EditorTextView.swift
│  ├─ EditorView.swift
│  ├─ EditorCoordinator.swift
│  └─ MarkerVisibility.swift
├─ Parsing/
│  ├─ MarkdownParser.swift        # swift-markdown 语义 AST
│  ├─ MarkdownTokenScanner.swift  # 源码 marker/token
│  └─ SourceIndex.swift           # UTF-8 ↔ UTF-16
├─ Rendering/
│  ├─ RenderPipeline.swift
│  ├─ RenderSnapshot.swift
│  ├─ RenderEngine.swift
│  └─ Theme.swift
├─ Behaviors/
│  └─ TypingBehaviors.swift
└─ Tests/
   ├─ SourceIndexTests.swift
   ├─ TokenScannerTests.swift
   ├─ RendererTests.swift
   ├─ BehaviorTests.swift
   ├─ IMEIntegrationTests.swift
   └─ PerformanceTests.swift
```

## 04 核心难点与对策

### 4.1 源码区间：UTF-8、UTF-16 与 token

swift-markdown 的 `SourceLocation` 使用 1-based 行号和 UTF-8 字节列；AppKit 的字符范围使用 UTF-16。`SourceIndex` 为每行缓存 UTF-8 与 UTF-16 起点，并提供经过边界检查的转换接口。

AST 只用于确定“这段内容是什么”，不承担精确定位所有 Markdown 标记。`MarkdownTokenScanner` 从原始源码提取：

- emphasis / strong / strikethrough delimiter；
- 行内代码与代码围栏；
- ATX 标题、引用、列表和任务框前缀；
- link/image 的 label、destination 与包围标记；
- 转义字符和暂未闭合的编辑中语法。

解析器输出最终统一为 UTF-16 `NSRange`，RenderEngine 不再接触 UTF-8 行列。

### 4.2 标记隐藏与光标处回显

默认策略仍为源码 1:1：marker 字符始终存在，只改变视觉属性。光标或选区进入对应 span 时，恢复其源码 marker；移出后隐藏或弱化。

实现分三级降级：

1. **首选：**验证零宽或近零宽 marker，不破坏换行、光标、选区、IME 和 VoiceOver。
2. **降级：**marker 使用弱化色和较小字号，但保留可预测宽度。
3. **后续：**若必须获得完全无缝的排版，再评估自定义 `NSTextLayoutFragment`，不在 MVP 中仓促实现。

M0 必须覆盖中文、emoji、组合字符、嵌套强调、跨行选择、自动换行、鼠标点击、方向键和 VoiceOver。通过前不承诺“完全零宽”。

### 4.3 块级编辑行为

在 `EditorTextView` / `TypingBehaviors` 中通过标准文本替换接口实现，确保每次操作进入文档 undo manager：

- 列表项 Enter 续项、空项 Enter 退出列表；
- 标题行首 Enter 断开标题；
- `**`、`*`、反引号的保守自动配对；
- 行首 `- `、`1. `、`- [ ]` 的块识别；
- undo/redo 后触发新的 revision 和派生渲染。

自动配对必须尊重选区、转义字符、已有闭合符号和 marked text；不要直接在 `keyDown` 中吞掉所有按键，优先使用 `NSTextViewDelegate` 的命令与替换入口。

### 4.4 中文输入法（IME）

字符数不变会显著降低 IME 风险，但不代表天然安全。规则如下：

1. `hasMarkedText` 为真时，不对 marked range 应用可能影响输入状态和布局的属性；
2. 上屏后再创建新 revision 并重新渲染；
3. 解析和渲染不得抢占主线程输入；
4. 建立拼音、双拼、五笔及系统英文输入的人工测试矩阵；
5. 覆盖强调、链接、列表、代码围栏内输入，以及候选状态下 Enter/Escape/方向键。

### 4.5 撤销 / 重做

撤销栈只包含源码变化：

- 普通键入由 `NSTextView` 原生 undo 管理；
- 自动配对、列表续行等复合操作显式组成单个 undo group；
- 主题、语法着色、marker 显隐和图片加载不注册 undo；
- undo/redo 结束后重新计算 RenderSnapshot；
- 不使用整篇字符串快照作为正式撤销模型。

### 4.6 并发与性能

- 主线程：接受输入、维护 selection、应用最新属性。
- 后台任务：解析不可变字符串快照，生成纯值 `RenderSnapshot`。
- 每次编辑递增 revision；旧任务可以被取消，即使不能及时取消，其结果也不得覆盖新 revision。
- 合并同一事件周期内的连续变化，但不假定“下一 runloop”天然满足性能目标。
- 对属性应用统计总耗时；优先更新变化块和可见区域，避免每次无条件重设整篇属性。

性能验收以实测为准：

| 文档规模 | 输入主线程预算 | 目标 |
|---|---:|---|
| 20KB | P95 < 8ms | 无可感知延迟 |
| 200KB | P95 < 16ms | 连续输入不丢帧、不跳光标 |
| 1MB | 不阻塞输入 | 允许渲染短暂滞后，源码编辑必须可用 |

若 200KB 不达标，Phase 2 采用自建 block index：从编辑点向两侧寻找安全块边界，只重扫受影响块，再与全量 AST 做低频校准。不能依赖 swift-markdown 未提供的公开增量解析能力。

### 4.7 图片

常规 `NSTextAttachment` 通常以 attachment character 表示附件，与“源码字符不变”的核心约束存在冲突。MVP 只提供图片语法样式、路径解析和悬浮/侧边预览；真正的行内图片进入 Phase 2，再选择以下方案之一：

- 自定义 TextKit 2 layout fragment；
- 额外的预览行或 overlay；
- 明确引入展示文本与源码之间的映射层。

## 05 MVP 范围

**做 · MVP**

- ATX 标题 1–6 级；
- 粗体、斜体、删除线、行内代码；
- 行内链接样式、点击打开、光标处回显源码；
- 图片语法样式与悬浮/侧边预览，不替换源码；
- 无序、有序和任务列表；
- 代码围栏，无语法高亮；
- 引用块背景和段落缩进；
- 分隔线；
- 亮暗主题，跟随系统；
- 打开、保存、autosave、撤销重做、源码模式切换；
- 查找替换、拼写检查等 `NSTextView` 原生能力；
- 基础 VoiceOver、Reduce Motion 和高对比度验收。

**不做 · Phase 2**

- 真正的零占位行内图片；
- 表格可视化编辑；
- 数学公式；
- 代码块语法高亮；
- 大纲 / TOC 侧栏；
- 导出 PDF / HTML；
- block 级增量解析与超大文件优化。

## 06 里程碑与验收门槛

| 阶段 | 工期 | 内容与退出条件 |
|---|---|---|
| M0 技术验证 | 3～5 天 | TextKit 2 明确启用；中英文/emoji 下区间正确；marker 隐藏、选区、换行、IME、undo、VoiceOver 可接受；20KB/200KB 基准有数据 |
| M1 骨架 | 1 周 | Xcode 工程；`NSDocument → EditorBuffer → NSTextStorage` 单一所有权；open/save/autosave；SwiftUI 外壳 |
| M2 解析与渲染 | 1.5～2 周 | `SourceIndex`、TokenScanner、后台 revision 管线；标题、强调、代码、链接；单元测试覆盖 Unicode 与未闭合语法 |
| M3 光标交互 | 1.5～2 周 | marker 回显、方向键、鼠标命中、跨行选区、源码模式；无 TextKit 1 fallback |
| M4 块行为 | 1 周 | 列表续行/退出、标题行为、任务列表、自动配对；复合操作一次撤销 |
| M5 收尾功能 | 1 周 | 代码围栏、引用、分隔线、图片预览、查找替换 |
| M6 稳定与发布准备 | 1～2 周 | IME 矩阵、autosave/reopen、崩溃恢复、性能、VoiceOver、主题和回归测试 |

M0 是 go/no-go gate。只有 M0 通过后才进入完整工程搭建；若只能做到 marker 弱化而不能可靠零宽，应在 M0 结束时接受降级设计并固定交互规范。

## 07 风险

| 风险 | 等级 | 对策 |
|---|---|---|
| UTF-8 `SourceRange` 与 UTF-16 `NSRange` 错位 | P0 | 独立 `SourceIndex`；中文、emoji、组合字符和多行 golden tests |
| AST 无法给出精确 marker token | P0 | AST 与轻量 TokenScanner 双层结构；覆盖转义、嵌套与未闭合语法 |
| 零宽 marker 破坏换行、命中或辅助功能 | P0 | M0 先验证；失败则降级为弱化显示，后续再做自定义 layout fragment |
| IME 与异步渲染互相干扰 | P0 | 跳过 marked range；后台快照 + revision；中文输入矩阵 |
| 文档模型与 text view 出现双重真相 | P0 | `EditorBuffer.textStorage` 是唯一可变正文；SwiftUI 不回写整篇字符串 |
| 派生属性污染 undo 栈 | P1 | undo 只记录源码；撤销后重算渲染，不做整篇快照式 undo |
| 200KB 文档输入卡顿 | P1 | 建立基准；后台解析、旧 revision 丢弃、变化块属性更新；必要时自建 block index |
| TextKit 2 意外降级为 TextKit 1 | P1 | 显式创建；禁止访问 `layoutManager`；开发期监听 fallback 通知并断言 |
| 行内图片破坏源码 1:1 | P1 | MVP 使用悬浮/侧边预览；真正 inline layout 移至 Phase 2 |
| 表格、公式和高亮拖慢首版 | P2 | 保持 Phase 2，不进入 MVP 验收 |

## 08 验证清单

### 正确性

- ASCII、中文、emoji、ZWJ emoji、组合附加符的 range 转换；
- 嵌套/相邻/转义/未闭合 Markdown 标记；
- CRLF、LF、空文档、超长单行；
- undo/redo 后源码、selection 和渲染一致；
- 源码模式切换不修改文件内容。

### 交互

- 拼音候选状态、上屏、取消和 Enter；
- marker 前后方向键、鼠标点击和跨 marker 选区；
- 粘贴、多光标不支持时的明确行为、拖放和链接点击；
- VoiceOver 朗读不重复或遗漏正文，隐藏 marker 不制造混乱；
- Reduce Motion、高对比度和系统字体缩放可用。

### 性能与文档生命周期

- 20KB、200KB、1MB 固定语料的输入延迟与解析耗时；
- 快速连续输入时旧 revision 不覆盖新内容；
- 打开、保存、Save As、autosave、reopen、外部文件变化与崩溃恢复；
- 多窗口/多文档之间的 text storage、undo manager 和主题状态完全隔离。

---

**下一步：**先实现 M0 技术验证工程，不直接铺开完整 UI。M0 产出应包括最小编辑器、range/token 测试、IME/选择行为记录和 20KB/200KB 性能报告；通过 gate 后再进入 M1。

## 参考资料

- [Apple：What's new in TextKit and text views](https://developer.apple.com/videos/play/wwdc2022/10090/)
- [Apple：TextKit](https://developer.apple.com/documentation/appkit/textkit)
- [Apple：NSTextAttachment](https://developer.apple.com/documentation/appkit/nstextattachment)
- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [swift-markdown SourceLocation](https://github.com/swiftlang/swift-markdown/blob/main/Sources/Markdown/Infrastructure/SourceLocation.swift)
