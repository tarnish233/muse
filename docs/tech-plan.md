# Muse 技术方案

一款极简即时渲染 Markdown 编辑器（对标 Typora），纯 macOS 原生实现。

- 版本：v0.4 · 2026-08-27
- 目标平台：macOS 14+
- 技术栈：Swift 6 · AppKit（TextKit 2）· SwiftUI · swift-markdown

> **v0.3 修订说明**：v0.2 的技术路线（NSTextView + TextKit 2 + swift-markdown）经 M0–M2 验证成立，保持不变。但 v0.2 对两个关键事实的判断是反的，v0.3 予以纠正；同时补入一次替代方案调研：
>
> 1. **swift-markdown 的能力被低估**。v0.2 §4.1 假设「AST 不承担精确定位所有 Markdown 标记」，据此立了一个独立的完整 tokenizer。实测 AST 对所有行内节点都给出精确字节区间，marker 位置可由父子区间相减得到，且 `***`、反向嵌套、未闭合、转义、CJK 邻接等难例全部已经正确。
> 2. **`NSTextLayoutFragment` 的必要性被推迟**。v0.2 §02/§4.2 把它列为「必要时」「Phase 2 再评估」。实测在 layer-backed 的 TextKit 2 `NSTextView` 上，视图级 `draw(_:)` / `drawBackground(in:)` 的输出会被完全覆盖——自定义 fragment 是任何块级视觉的唯一入口，属于 MVP 地基而非后续优化。
> 3. **替代方案已实测排除**（新增 §2.1）。macOS 26 的 `TextEditor(text: $attributedString)`、STTextView、CodeEditTextView 三条路线逐一核验，结论是继续走 A 方案；细节与依据见 §2.1。
>
> 详见 §2.1、§4.1、§4.2、§4.8 与《M2 评价报告》。

> **v0.4 工作区修订说明**：SwiftUI 外壳不再展示“假项目 + 当前文稿”静态列表，改为 Codex 风格的真实目录工作区。三列布局、侧栏表面、宽度、分隔线与开合状态均由 Muse 自己控制，不使用 `NavigationSplitView`、系统 sidebar `List` 或 `.inspector`；左侧项目可展开为文件树，并支持新建项目、打开项目、在项目或任意文件夹中新建文件/文件夹。文件与文档生命周期仍优先使用 macOS 官方 API，详见《工作区与侧栏重构报告》及 §3.1。

---

## 00 本轮视觉复查（2026-08-27）

本轮对照截图复查发现并修复了四项列表视觉缺陷：

1. 软换行列表项的一个 paragraph fragment 覆盖多条 `NSTextLineFragment`。旧实现按整个 paragraph fragment 的高度居中 marker，导致 marker 落在段落中部；现改为锚定首个 `textLineFragments.first`。
2. 二级无序 marker 虽然由 AST depth 选择 `◦`，字体 fallback 仍可能把 U+25E6 画成实心点。现在由 `.museListDepth` 驱动 glyph 判定，并在 fragment 绘制层用矢量实心圆、空心圆和方块，确保二级中心留空；绘制层不从源码缩进重新推导 depth。
3. 首行行框包含 glyph 上下方的 leading；把较小字号 marker 居中到 `typographicBounds` 会使圆点和序号整体高于正文。现在读取首个 line fragment 的 `glyphOrigin.y`：有序序号与 checkbox 按 marker font ascender 对齐正文 baseline，无序矢量符号对齐正文 font 的 x-height 视觉中心，不使用固定像素补偿。
4. 有序 marker 旧按自身宽度从正文列向左回推，等同于右对齐；数字 `1` 与 `2` 的可见左边界因字形 side bearing 不同而出现细微错位，也无法与无序 marker 共用稳定左边界。现在 marker 使用段落 `headIndent - firstLineHeadIndent` 推导出的固定槽位，文本 marker 以 Core Text 的实际 glyph path bounds 补偿可见墨迹左边界；多位序号按实际 glyph advance 二分求取槽内最大字号，保留正文列并避免侵入正文。

任务 checkbox 的 checked marker 使用系统 accent 色，unchecked marker 使用 `secondaryLabelColor`，两者都按浅色/深色外观解析。本轮只完成颜色与绘制，不实现点击切换；checkbox 点击将留到 M4，并通过标准文本编辑把 `[ ]`/`[x]` 替换为一次可撤销的源码操作。

本轮新增 6 项真实 TextKit 2/位图回归测试；最新 Debug 全量证据为 **109 tests / 7 suites**，其中 `RendererTests` 为 **33 项**。这组证据验证了首行锚定、无序 marker 的 x-height 对齐、有序 marker 的 baseline 与固定槽位、`1.`/`2.` 的可见墨迹左边界、`98.`/`99.`/`100.` 不侵入正文、一级实心与二级空心的实际 fragment 像素，以及任务 checkbox 的外观颜色。

根任务以独立 bundle 启动 Debug App 做了视觉人工复查，已确认长列表 marker 位于第一视觉行、无序 marker 与正文 x-height 居中、有序序号与正文基线一致、二级 marker 明确为空心、checked checkbox 使用蓝色强调而 unchecked checkbox 使用灰色轮廓。本结果只覆盖本轮列表/checkbox 外观，不等同于 M0-3 的 IME、VoiceOver、零宽 marker、完整外观热切换等清单已全部完成。

## 01 结论

**技术路线保持不变：使用 AppKit 的 `NSTextView`（TextKit 2）作为编辑核心，SwiftUI 作为应用外壳，swift-markdown 负责 Markdown 解析。**

但实现必须遵守以下边界：

1. `NSTextStorage` 是编辑期唯一可变文本；`NSDocument` 只负责持有编辑缓冲区、序列化和文档生命周期，不能再维护第二份可变 `String`。
2. 保存内容始终是完整 Markdown 源码。渲染属性、AST、token、图片和主题都是可丢弃、可重建的派生状态。
3. **swift-markdown 是语义与源码定位的唯一来源**。marker 的字节边界从 AST 的父子区间推导，不另建一套 CommonMark 实现。轻量扫描器只负责 AST 按定义不产出节点的情况——主要是编辑中的未闭合语法。
4. 使用 `SourceIndex` 显式完成 swift-markdown 的 UTF-8 行列位置与 `NSTextStorage` 的 UTF-16 `NSRange` 之间的转换。
5. 标记隐藏采用「源码字符不删除 + 光标处回显」，通过属性层实现（近零宽 + 透明）。
6. **块级视觉（列表符号、引用竖线、通宽背景、分隔线横线）必须通过自定义 `NSTextLayoutFragment` 绘制。** 视图级绘制钩子在 layer-backed 的 TextKit 2 上无效，这是地基而非可选项。
7. undo/redo 只记录源码修改；渲染属性不进入撤销栈，文本撤销后重新计算渲染结果。
8. 解析在后台处理不可变快照并带 revision。整篇解析是否够用，以「样式落地延迟」实测结果决定（见 §4.6）。

**工作量预期：**可演示 MVP 约 6～8 周全职；达到可长期日用的稳定程度约 8～12 周。M0 是开工门槛，但 v0.2 版的 M0 gate 遗漏了绘制层验收（见《M0 评价报告》§8），v0.3 已补入。

## 02 方案对比

| 方案 | 手感 / 输入法 | 开发量 | 结论 |
|---|---|---|---|
| A · 原生 `NSTextView` + TextKit 2 | 系统原生编辑、IME、滚动和辅助功能基础最好 | 编辑语义与块级绘制需要自研 | ✅ 推荐（选定，M0–M2 已验证） |
| B · 原生壳 + `WKWebView` + CodeMirror 6 / Milkdown | 开发快，但输入、字体与系统服务隔着 WebKit | 数周可形成可用原型 | ⚠️ 已不再需要（M0 gate 通过） |
| C · SwiftUI `TextEditor` + `AttributedString` | 原生输入，但拿不到排版层 | 表面最省 | ❌ 排除（见 §2.1，实测三处硬阻塞） |
| D · 自研排版引擎（不用 TextKit） | 需自建 IME / 选区 / 无障碍 | 极大 | ❌ 排除（见 §2.1） |

补充约束：

- 明确使用 TextKit 2 手工栈（`NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer → NSTextView`），并在代码审查中禁止访问 TextKit 1 的 `layoutManager`，避免不可逆地进入兼容模式。
- SwiftUI 只承载窗口内容、侧栏、工具栏、设置与状态展示；不要让 `updateNSView` 持续把整篇字符串回写给 `NSTextView`。
- 文档采用 AppKit `NSDocument` 生命周期：`MuseDocument` 持有 `EditorBuffer`，窗口内容通过 `NSWindowController` / `NSHostingController` 组合 SwiftUI 与 AppKit。
- **自定义 `NSTextLayoutFragment` 是块级视觉的唯一入口**，不是"必要时"的备选。SwiftUI 宿主视图会强制整个子树 layer-backing，`wantsLayer = false` 无效。
- SPM 依赖只有 `swift-markdown`；它与底层 cmark-gfm 都不提供增量解析 API，不要假设存在（已在 swift-markdown 仓库源码层面确认：`incremental` 只出现在 `BlockDirectiveParser.swift` 与一个计数器测试中，无 reparse/partial 公开接口）。

### 2.1 替代方案调研（2026-08-27）

**C · SwiftUI `TextEditor(text: $attributedString)` —— 排除，三处硬阻塞**

API 确实存在（macOS SDK 26.5 的 `SwiftUI.swiftinterface` 实测）：

```swift
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public init(text: Binding<AttributedString>,
            selection: Binding<AttributedTextSelection>? = nil)
```

格式由 `attributedTextFormattingDefinition(_:)` + `AttributedTextFormattingDefinition`（约束到某个 `AttributeScope`）控制。但对 Muse 有三处不可绕过的阻塞：

1. **没有 `paragraphStyle`。** `AttributeScopes.SwiftUIAttributes` 只含 `font` / `foregroundColor` / `backgroundColor` / `strikethroughStyle` / `underlineStyle` / `kern` / `tracking` / `baselineOffset`，macOS 26 新增 `alignment` 与 `lineHeight`。全 SDK 搜不到任何 SwiftUI scope 暴露 `paragraphStyle`。列表悬挂缩进（`firstLineHeadIndent` / `headIndent`）与嵌套层级缩进因此无法表达——而这是列表渲染的核心。
2. **`AttributedString` 的 Markdown 是只进不出。** Foundation 只提供 `init(markdown:)` 系列，没有任何序列化/导出接口。「保存内容始终是完整 Markdown 源码」这条铁律直接失效。
3. **拿不到排版层。** 没有 `NSTextView`、没有 `NSTextLayoutFragment`、没有绘制钩子。§4.8 列出的块级视觉（引用竖线、通宽背景、列表符号、分隔线横线）全部无法实现。

附带发现（可能对 Phase 2 有用）：`AttributedString.MarkdownParsingOptions` 有 `appliesSourcePositionAttributes`，配合 `AttributedString.MarkdownSourcePosition` 能让 Foundation 的 Markdown 解析器输出源码位置。但它仍然只解析不导出，且 `interpretedSyntax` 会吃掉标记字符，不适用于「源码 1:1」的即时渲染。

**结论**：v0.2 排除 SwiftUI `TextEditor` 的判断正确，v0.3 给出了具体依据，避免以后重复评估。

**STTextView（krzyzanowskim）—— 作为参考，不作为依赖**

TextKit 2 的 `NSTextView`/`UITextView` 替代组件，1.5k star，维护活跃（最近推送 2026-08-18）。它的架构与 Muse 在 M2 收口后落地的方案一致：`STTextLayoutFragment` + `STTextView+NSTextLayoutManagerDelegate` + `STTextLayoutFragmentView`——这是对 §4.8 技术选择的独立印证。

两个原因不引入为依赖：

- **授权**：GPL v3 或付费商业授权。闭源产品需购买商业许可。
- **定位**：它替换的是整个 text view，而 Muse 需要的是 `NSTextView` 的原生编辑语义（IME、无障碍、查找、拼写），只在绘制层做扩展。

**但它的价值很高**：作者维护了一份公开的 TextKit 2 缺陷清单（README「TextKit 2 Bug Reports List」），且明确说明该项目存在的原因就是「NSTextView + TextKit 2 并不完全可用，被具体 bug 阻塞后才另起项目」。与 Muse 直接相关的条目见 §4.8。

**D · CodeEditTextView / CodeEditSourceEditor（CodeEditApp）—— 排除**

CodeEditTextView 是**完全自研的排版引擎**，不使用 TextKit（源码中检索不到 `NSTextLayoutManager`）：自建 `TextLayoutManager`、`TextLineStorage`、`TextLine`、`TextSelectionManager`、`MarkedTextManager`。MIT 授权。CodeEditSourceEditor 在其上叠加 tree-sitter 语法高亮。

它的 README 明确划出了自身边界：如果需要「右到左文本、自定义布局元素、或与系统 text view 的功能对等」，应当用 STTextView 或 `NSTextView`。这三项恰好都是 Muse 的需求，所以这条路线不适用——它是「为代码文档换取极快首屏布局」的取舍，而 Muse 要的是富文本布局与系统级编辑语义。

**这仍是一个值得记住的数据点**：一个严肃的开源编辑器项目评估 TextKit 后选择自研，说明 TextKit 2 的成熟度确实有限（与 STTextView 的缺陷清单互相印证）。若 Muse 后期在 TextKit 2 上遇到不可绕过的阻塞，D 是唯一的兜底，但代价是重建 IME 与无障碍。

**自定义 fragment 做 Markdown 渲染已有先例**

多个开源项目采用同一模式，文件名甚至一致：`nodes-app/swift-markdown-engine` 的 `MarkdownTextLayoutFragment.swift`、`no-problem-dev/swift-markdown-view` 的 `MarkdownLayoutFragment.swift`、`bharathvbcr/MarkDev` 的 `MarkdownLayoutFragment.swift`（注释写明「Custom drawing behind code blocks, callouts, quotes, and rules」）。§4.8 的一条实现风险就来自阅读 MarkDev 的源码注释。

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
│ Render Pipeline（后台）                              │
│ String Snapshot + revision                           │
│   ├─ swift-markdown：AST = 语义 + 精确源码区间        │
│   ├─ MarkerDeriver：父子区间相减 → marker 字节边界    │
│   ├─ TokenScanner：仅补未闭合语法（编辑中态）         │
│   └─ SourceIndex：UTF-8 → UTF-16 NSRange             │
│                    ↓                                 │
│ RenderSnapshot(revision, spans, markers, blocks)     │
│                    ↓ 仅接受最新 revision             │
├──────────────────────────────────────────────────────┤
│ 主线程输出（两层，缺一不可）                          │
│   ├─ 属性层：字体/颜色/段落/marker 显隐 → NSTextStorage│
│   └─ 绘制层：MuseLayoutFragment 画块级视觉            │
│        由存储上的 .museBlock 属性驱动                 │
└──────────────────────────────────────────────────────┘
```

### 3.1 工作区与侧栏

工作区是文档生命周期之外的一层导航状态，不复制正文，也不替代 `NSDocument`：

```text
ProjectWorkspace（@Observable，全窗口共享）
├─ security-scoped bookmark → 恢复项目目录
├─ FileManager → 创建/枚举目录与文件
├─ WorkspaceProject → 项目根目录
└─ WorkspaceNode → 可递归展开的文件树
                           │ 点击 Markdown/纯文本文件
                           ▼
NSDocumentController → MuseDocument → EditorBuffer
```

界面外壳由 `EditorChromeState + ZStack/HStack` 组成三个固定语义区域。窗口启用 `fullSizeContentView`，但不创建 `NSToolbar`；46pt 自绘标题栏与左、中、右三列共享边界。侧栏在视图树中持续存在，通过宽度、透明度和命中状态开合，避免重建编辑器；自定义 1pt 分隔线带 9pt 拖拽命中区。左栏与右栏默认宽度分别为 280pt、300pt，均可在 240–380pt 范围调整。

- “新建项目”使用 `NSSavePanel` 选择名称与位置，再由 `FileManager.createDirectory` 创建真实目录。
- “打开项目”使用 `NSOpenPanel` 选择现有目录。
- 项目入口通过 security-scoped bookmark 写入 `UserDefaults`，下次启动恢复；正文不进入偏好存储。
- 新建文件与文件夹可以作用于项目根目录或任意子文件夹；无扩展名的新文件自动补 `.md`。
- 文件按“文件夹优先 + Finder 本地化自然顺序”排列；隐藏文件和 package 后代默认不进入树。
- 点击可编辑文件统一交给 `NSDocumentController.openDocument(..., display: false)` 读取和注册，再由当前 `EditorWindowController` 通过 `removeWindowController` / `addWindowController` 迁移到目标文档；切换前调用 `NSDocument.canClose`，有未保存修改时保留系统保存提示。
- 项目根目录默认展开，子文件夹默认收起；点击一个目录只展示它的直接子层，不连带展开更深层目录。
- “从侧边栏移除”只移除工作区引用并释放安全作用域，不删除磁盘目录。
- 不使用 `NavigationSplitView`、`.inspector`、`.listStyle(.sidebar)`、`NSToolbar`、`DisclosureGroup` 或 `OutlineGroup`。项目树、标题栏和侧栏按钮均由 Muse 自己布局。
- 左右开关是 28pt ghost button：默认无边框无底色，悬停时出现低对比填充；左开关固定在交通灯之后，右开关固定在窗口最右侧。
- 侧栏开合使用可打断、无过冲的 spring（response 0.28 / damping 1.0）；“减少动态效果”开启时改为近乎即时切换。
- 右侧大纲没有“大纲”标题、顶部横线或人为占位；无标题时使用 `ContentUnavailableView`。
- 编辑器右下状态显示 `字符: <字符数>  渲染: <耗时>ms`，并为垂直滚动条预留 30pt 右侧间距。

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
→ 后台解析 AST、推导 marker、构建区间索引
→ 生成 RenderSnapshot
→ MainActor 检查 revision
→ 批量应用最新渲染结果（属性层 + 触发绘制层重绘）
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
│  └─ main.swift
├─ Document/
│  ├─ MuseDocument.swift
│  ├─ EditorBuffer.swift          # 持有唯一 NSTextStorage
│  ├─ RenderCoordinator.swift     # 两条更新流的调度
│  └─ SampleMarkdown.swift
├─ Editor/
│  ├─ EditorTextView.swift        # TextKit 2 手工栈 + fragment 工厂挂接
│  ├─ EditorView.swift            # NSViewRepresentable 桥
│  ├─ EditorShellView.swift        # 自绘标题栏、三列、宽度与开合动画
│  ├─ CodexDocumentTitlebar.swift  # 中央文稿标题栏
│  ├─ CodexTitlebarButton.swift    # 扁平 ghost 开关
│  ├─ EditorChromeMetrics.swift    # 标题栏与侧栏几何常量
│  ├─ EditorChromeState.swift      # 两侧栏窗口级状态
│  ├─ SidebarResizeHandle.swift    # 自定义可拖拽分隔线
│  ├─ DocumentOutlineView.swift
│  └─ Workspace/                   # 项目持久化、目录树与文件操作
├─ Parsing/
│  ├─ MarkdownSemantics.swift     # swift-markdown AST → 语义 + marker 区间
│  ├─ TokenScanner.swift          # 仅未闭合语法（编辑中态）
│  ├─ Token.swift
│  └─ SourceIndex.swift           # UTF-8 ↔ UTF-16
├─ Rendering/
│  ├─ RenderEngine.swift          # 属性层
│  ├─ BlockLayoutFragment.swift   # 绘制层（MuseLayoutFragment）
│  └─ Theme.swift
├─ Behaviors/
│  └─ TypingBehaviors.swift       # M4
└─ MuseTests/
   ├─ SourceIndexTests.swift
   ├─ TokenScannerTests.swift
   ├─ MarkdownSemanticsTests.swift
   ├─ RendererTests.swift
   ├─ CoordinatorPipelineTests.swift
   ├─ DocumentTests.swift
   ├─ WorkspaceTests.swift
   └─ PerformanceTests.swift
```

## 04 核心难点与对策

### 4.1 源码区间：AST 即定位来源

swift-markdown 的 `SourceLocation` 使用 1-based 行号和 UTF-8 字节列；AppKit 的字符范围使用 UTF-16。`SourceIndex` 为每行缓存 UTF-8 与 UTF-16 起点，并提供经过边界检查的转换接口。

**AST 同时回答「这段内容是什么」和「它在源码的哪里」。** 实测（swift-markdown 0.8.0）所有行内节点都带精确字节区间：

```text
Strong bytes=0..<10 → "**粗体**"
  Text bytes=2..<8   → "粗体"
```

marker 边界由减法得到，无需重新实现分隔符匹配：

- 开标记 = `节点.range.lower ..< 首子.range.lower`
- 闭标记 = `末子.range.upper ..< 节点.range.upper`

以下难例 AST 全部已经正确，**不需要自建 delimiter run / flanking / mod-3 实现**：

| 难例 | AST 结果 |
|---|---|
| `***三层星号***` | `Emphasis(Strong(Text))` 正确嵌套 |
| `*a **b** c*` | 反向嵌套正确 |
| `**未闭合` | 不生成 Strong，保持 `Text`（标记自然保持可见） |
| `\*不是强调\*` | 转义生效，保持 `Text` |
| `**粗体**、` | CJK 紧邻正常成对，无需自定义标点集 |

AST 还直接提供以下结构信息（v0.2 未使用，实测均可取）：

| 信息 | 取法 |
|---|---|
| 列表嵌套深度 | `ListItem` 父链中 `UnorderedList`/`OrderedList` 计数 |
| 有序列表起始序号 | `OrderedList.startIndex` |
| 任务框勾选态 | `ListItem.checkbox` |
| 代码块语言 | `CodeBlock.language` |
| 表格结构 | `Table` / `Head` / `Body` / `Row` / `Cell`，默认选项即解析，全部带 source position |

**扫描器的剩余职责**：AST 按 CommonMark 定义不为未闭合语法生成节点（这是正确行为），但编辑中态需要知道「这里正在输入一个粗体」以决定 marker 显隐。这是唯一需要字节级扫描的场景，范围应严格限制在此，不得再扩张成第二套 CommonMark 实现——两套实现会产生语义分叉（v0.2 期间实际发生过：扫描器把 `a*b*c` 判为字面量，cmark 判为 `Emphasis`）。

解析器输出最终统一为 UTF-16 `NSRange`，RenderEngine 不再接触 UTF-8 行列。

### 4.2 标记隐藏与光标处回显

marker 字符始终存在，只改变视觉属性。光标或选区进入对应 span 时恢复源码 marker，移出后隐藏或弱化。两种状态：

| 状态 | 实现 | 用于 |
|---|---|---|
| `revealed` | 正常字号 + 弱化色 | 光标所在行/块 |
| `hidden` | 近零宽字体（0.1pt）+ 透明 | 行内、列表/任务、引用/围栏/分隔线标记；列表图形由绘制层在段落 marker 带画出 |

M0 已验证近零宽方案在中文、emoji、组合字符、跨行选择、自动换行、鼠标点击、方向键下工作正常。降级路径（marker 改弱化色 + 小字号）保留但未启用。

> v0.2 把「自定义 `NSTextLayoutFragment`」列为本节的第三级降级选项。这是分类错误：marker 隐藏（属性层）与块级视觉（绘制层）是两件正交的事，fragment 属于后者且不可绕过。见 §4.8。

### 4.3 块级编辑行为

在 `EditorTextView` / `TypingBehaviors` 中通过标准文本替换接口实现，确保每次操作进入文档 undo manager：

- 列表项 Enter 续项、空项 Enter 退出列表；
- 标题行首 Enter 断开标题；
- `**`、`*`、反引号的保守自动配对；
- 行首 `- `、`1. `、`- [ ]` 的块识别；
- 任务 checkbox 点击切换属于 M4：命中图形后通过标准文本编辑将源码 `[ ]`/`[x]` 替换，并作为一次 undo 操作；当前只绘制 checkbox，尚未提供点击切换；
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

- 主线程：接受输入、维护 selection、应用最新属性、绘制块视觉。
- 后台任务：解析不可变字符串快照，生成纯值 `RenderSnapshot`。
- 每次编辑递增 revision；旧任务可以被取消，即使不能及时取消，其结果也不得覆盖新 revision。
- 合并同一事件周期内的连续变化，但不假定「下一 runloop」天然满足性能目标。
- 对属性应用统计总耗时；优先更新变化块和可见区域，避免每次无条件重设整篇属性。

**两类指标必须分开验收**（v0.2 只定义了前者，导致解析成本无从判断）：

输入响应——主线程预算，决定「打字是否卡」：

| 文档规模 | 输入主线程预算 | 目标 |
|---|---:|---|
| 20KB | P95 < 8ms | 无可感知延迟 |
| 200KB | P95 < 16ms | 连续输入不丢帧、不跳光标 |
| 1MB | 不阻塞输入 | 允许渲染短暂滞后，源码编辑必须可用 |

样式落地延迟——编辑到样式可见的端到端时间，决定「渲染是否跟手」：

| 文档规模 | 目标 | 说明 |
|---|---:|---|
| 20KB | < 50ms | 感觉即时 |
| 200KB | < 150ms | 可察觉但不干扰 |
| 1MB | 尽力而为 | 允许明显滞后 |

**解析成本实测**（swift-markdown 0.8.0，Apple Silicon）：

| 文档规模 | 全文档 AST 解析（Debug） | 全文档 AST 解析（Release） |
|---|---:|---:|
| 20KB | 9.350 ms | 3.565 ms |
| 200KB | 97.765 ms | 36.665 ms |

M1-2 已恢复 Release 测量链路；历史 Release 全量测试为 103 项 / 7 套件全绿。作为历史对比，v0.2 的手写字节扫描器在 200KB 上是 8.0 ms，但当前全量 AST 仍落在后台与 150ms 样式落地目标内，因此不需要维护第二套 CommonMark 实现。最新 Debug 回归（含本轮 6 项渲染测试）为 109 项 / 7 套件全绿。

因此顺序是：**先用全量 AST 解析，把架构简化下来**；只有当样式落地延迟实测不达标时，才引入块级脏区重解析——即定位变化所在的顶层块，只对该块调用 `Document(parsing:)`，而不是维护第二套 CommonMark 实现。swift-markdown 与 cmark-gfm 都不提供增量解析 API。

### 4.7 图片

常规 `NSTextAttachment` 通常以 attachment character 表示附件，与「源码字符不变」的核心约束存在冲突。MVP 只提供图片语法样式、路径解析和悬浮/侧边预览。

真正的行内图片进入 Phase 2。由于 §4.8 已经把自定义 fragment 作为既有设施引入，Phase 2 的首选方案是在 fragment 中绘制图片，其次是额外预览行 / overlay。

### 4.8 块级视觉：绘制层

文本属性只能把背景画到字形宽度。以下需求无法用属性表达，必须绘制：

- 引用块整行通宽背景 + 左侧竖线
- 代码块整行通宽背景（含开/闭栏行）
- 分隔线的真实横线（marker 隐藏后行内无字形）
- 列表图形符号：圆点 / 序号 / 复选框

**实现路径只有一条：自定义 `NSTextLayoutFragment`，通过 `NSTextLayoutManagerDelegate` 提供。**

实测结论（macOS 26 / Xcode 26）：在 layer-backed 的 TextKit 2 `NSTextView` 上，视图级 `draw(_:)` 与 `drawBackground(in:)` 的输出被完全覆盖——填一个 300×300 的实色块，一个像素都不可见。字形被渲染进各 fragment 自己的图层，视图自身的绘制在其下方且被背景覆盖。SwiftUI 宿主视图强制整个子树 layer-backing，设 `wantsLayer = false` 无效（运行时实测仍为 `true`）。

关键实现细节：

1. **绘制时机**：override `draw(at:in:)`，先画装饰再 `super.draw`（字形）。
2. **渲染面必须扩宽**：通宽背景超出字形包围盒，需 override `renderingSurfaceBounds` 并 union 到容器宽度，否则被裁掉。
3. **块归属来源**：自定义属性 `.museBlock` 由属性层随样式写入整行/整块，fragment 直接读 `NSTextParagraph.attributedString` 的首字符属性——不需要回查 storage 偏移，也不需要自建缓存。
4. **坐标**：`draw(at:in:)` 的 `point` 是 fragment 局部原点（实测恒为 `(0,0)`）；容器左边缘 = `point.x - layoutFragmentFrame.minX`。绘制文本需要一个 `flipped: true` 的 `NSGraphicsContext`。
5. **隔离**：基类接口是 nonisolated，主题需相应声明 nonisolated（AppKit 只在主线程调用这些接口）。
6. **列表 marker**：软换行时以 `textLineFragments.first` 的真实 line geometry 锚定 marker，而不是用整个 paragraph fragment 的高度居中；无序 marker 的 depth 直接读取 AST 写入的 `.museListDepth`，并用矢量实心圆/空心圆/方块保证二级视觉留空；同层有序/无序 marker 使用段落缩进推导的固定槽位，有序文本按 Core Text glyph path bounds 补偿可见左边界，多位序号在槽内适配且不移动正文列。
7. **任务 checkbox**：checked 使用系统 accent 色，unchecked 使用外观感知的 `secondaryLabelColor`；本轮只完成绘制颜色，图形命中与源码 `[ ]`/`[x]` 标准替换及一次撤销列入 M4。

**已知的 TextKit 2 缺陷（来自 STTextView 维护者提交给 Apple 的公开清单，见 §2.1 与参考资料）。** 与本节直接相关的几条，在实现和排错时应当预期：

| 编号 | 问题 | 对 Muse 的影响 |
|---|---|---|
| FB9692714 | Rendering attributes do not draw properly | 属性层与绘制层不一致时的首查方向 |
| FB9856587 | 最后一行出现多余的 line fragment | 文末块视觉可能画错位置 |
| FB15131180 / FB22524198 | extra line fragment 尺寸不正确；`extraLineFragmentAttributes` 是私有 API，导致无法正确计算 | 文末空行的块视觉高度无法可靠算出 |
| FB13272586 | `NSTextContainer.size` 默认值与文档不符 | 通宽背景依赖容器宽度，需防御 0 / 极大值 |

另有一条**私有 API 依赖**值得知道：STTextView 的 fragment 在 `state < .layoutAvailable` 时会通过混淆的 selector 调用私有的 `layout` 方法，作者注明「没有公开 API 提供这个能力」。Muse 目前靠 `enumerateTextLayoutFragments(options: .ensuresLayout)` 规避，但这说明「绘制时 fragment 尚未排版」是 TextKit 2 的真实缺口，若后续遇到首帧块视觉缺失，根因可能在此。

**实现风险：动态色跨外观失效（机制已修复；本轮列表/checkbox 外观已人工通过）。**

`NSColor.cgColor` 对动态色（`NSColor(name:dynamicProvider:)`）按 `NSAppearance.current` 解析。实测：

```text
NSAppearance.current = .aqua     → [0.96, 0.97, 0.98, 1.0]
NSAppearance.current = .darkAqua → [0.15, 0.17, 0.19, 1.0]
NSAppearance.current = nil       → [0.96, 0.97, 0.98, 1.0]   ← 静默回落到亮色
```

`current` 未设置时**不报错、直接给亮色**。而 fragment 的绘制回调早于 actor 标注、也不保证运行在视图的外观上下文里，因此「在 `draw(at:in:)` 里对动态 `NSColor` 取 `.cgColor`」有两重风险：

1. 绘制时 `NSAppearance.current` 未指向视图外观 → 暗色模式下块视觉画成亮色；
2. 即使绘制时外观正确，TextKit 会按 text element 缓存并复用 fragment，外观切换后未必重绘全部 fragment → 残留旧外观的颜色。

对策：不在 fragment 内解析动态色，改为持有一份**共享的、已解析的 `CGColor` 调色板**，在外观变化时整体替换（同一实例换内容，而不是每个 fragment 各持一份副本——副本会比它被解析时的外观活得更久）。块视觉调色板与任务 checkbox 的 checked accent / unchecked secondary label 已接入；独立 Debug App 窗口已人工通过本轮列表/checkbox 外观复查，但这不替代 M0-3 的 IME、VoiceOver、零宽 marker 与完整外观热切换清单。

**测试必须走真实 fragment 路径。** 直接调用绘制函数往位图里画会绕过 TextKit 图层路径，产生「真机全白、测试全绿」的假绿——v0.2 期间实际发生过（见《M2 评价报告》§4）。断言应落在「`layoutManager` 确实生产自定义 fragment」加「该 fragment 的绘制确实落墨」上。

## 05 MVP 范围

**做 · MVP**

- ATX 标题 1–6 级；
- 粗体、斜体、删除线、行内代码；
- 行内链接样式、点击打开、光标处回显源码；
- 图片语法样式与悬浮/侧边预览，不替换源码；
- 无序、有序和任务列表的渲染，**含嵌套层级缩进与分级符号**；任务 checkbox 点击切换留到 M4；
- 代码围栏，无语法高亮；
- 引用块通宽背景 + 左竖线；
- 分隔线；
- 亮暗主题，跟随系统；
- 打开、保存、autosave、撤销重做、源码模式切换；
- 查找替换、拼写检查等 `NSTextView` 原生能力；
- 基础 VoiceOver、Reduce Motion 和高对比度验收。

**候选 · 视 M3 进度决定**

- 表格渲染（只读呈现）。解析层免费——AST 默认就产出带 source position 的 `Table`/`Row`/`Cell`；成本只在绘制。表格的**可视化编辑**仍留 Phase 2。

**不做 · Phase 2**

- 真正的零占位行内图片；
- 表格可视化编辑（列宽拖拽、增删行列）；
- 数学公式；
- 代码块语法高亮；
- 大纲 / TOC 侧栏；
- 导出 PDF / HTML；
- block 级增量解析与超大文件优化。

## 06 里程碑与验收门槛

| 阶段 | 工期 | 内容与退出条件 | 状态 |
|---|---|---|---|
| M0 技术验证 | 3～5 天 | TextKit 2 明确启用；中英文/emoji 下区间正确；marker 隐藏、选区、换行、IME、undo、VoiceOver 可接受；**块级视觉在真机窗口中可见**；20KB/200KB 基准有数据 | ✅ 通过（绘制层验收后补，见 M0 报告 §8） |
| M1 骨架 | 1 周 | Xcode 工程；`NSDocument → EditorBuffer → NSTextStorage` 单一所有权；open/save/autosave；SwiftUI 外壳 | ✅ 通过 |
| M2 解析与渲染 | 1.5～2 周 | `SourceIndex`、AST 语义层、后台 revision 管线；标题、强调、代码、链接；**块级视觉绘制地基（自定义 fragment）**；单元测试覆盖 Unicode 与未闭合语法 | ✅ 通过（M2-1～M2-9 已收口，见 M2 报告 §9.10） |
| M3 光标交互 | 1.5～2 周 | marker 回显、方向键、鼠标命中、跨行选区、源码模式；无 TextKit 1 fallback | 未开始 |
| M4 块行为 | 1 周 | 列表续行/退出、标题行为、任务 checkbox 点击将源码 `[ ]`/`[x]` 标准替换、自动配对；复合操作一次撤销 | 未开始 |
| M5 收尾功能 | 1 周 | 图片预览、查找替换、源码模式打磨、（候选）表格渲染 | 未开始 |
| M6 稳定与发布准备 | 1～2 周 | IME 矩阵、autosave/reopen、崩溃恢复、性能、VoiceOver、主题和回归测试 | 未开始 |

**v0.3 对里程碑的两处调整：**

1. **块级视觉从 M5 前移到 M2/M3。** v0.2 把「代码围栏、引用、分隔线」放在 M5「收尾功能」，但它们依赖 §4.8 的绘制地基。把地基放在最后一个功能里程碑等于把最大的架构风险留到最后；实际也已经发生——这些功能在 M2 期间被提前实现，但因地基缺失全部不可见。M5 相应改为图片预览与打磨。
2. **M0 gate 补入绘制层验收。** v0.2 版 M0 的十项人工验收全部围绕属性层，没有一项检查块级视觉能否画出来，导致假绿测试存活。

M0 仍是 go/no-go gate。

## 07 风险

| 风险 | 等级 | 对策 |
|---|---|---|
| UTF-8 `SourceRange` 与 UTF-16 `NSRange` 错位 | P0 | 独立 `SourceIndex`；中文、emoji、组合字符和多行 golden tests |
| 视图级绘制在 layer-backed TextKit 2 上无效 | P0 | 块级视觉一律走自定义 `NSTextLayoutFragment`；测试断言必须经由 `layoutManager` 真实生产的 fragment（§4.8） |
| 双层解析实现产生语义分叉 | P0 | AST 是唯一语义与定位来源；扫描器职责严格限于未闭合语法；对 AST 做差异测试（§4.1） |
| 零宽 marker 破坏换行、命中或辅助功能 | P0 | M0 已验证通过；降级路径（弱化显示）保留 |
| IME 与异步渲染互相干扰 | P0 | 跳过 marked range；后台快照 + revision；中文输入矩阵 |
| 文档模型与 text view 出现双重真相 | P0 | `EditorBuffer.textStorage` 是唯一可变正文；SwiftUI 不回写整篇字符串 |
| 测试绕过真实渲染路径产生假绿 | P1 | 渲染测试必须走 `NSTextLayoutManager` / `NSTextStorage` 真实路径；禁止直接调用绘制函数断言像素 |
| fragment 内解析动态色导致暗色模式失效 | P1 | 不在 fragment 内取 `NSColor.cgColor`（`NSAppearance.current` 为 nil 时静默回落亮色）；改用共享的已解析 `CGColor` 调色板，外观变化时整体替换（§4.8） |
| TextKit 2 自身缺陷（多余 line fragment、私有 API 依赖等） | P1 | 参照 STTextView 公开的缺陷清单预判（§2.1、§4.8）；文末空行与首帧块视觉专项检查 |
| 派生属性污染 undo 栈 | P1 | undo 只记录源码；撤销后重算渲染，不做整篇快照式 undo |
| 样式落地延迟不达标 | P1 | 先测全量 AST（200KB 实测 65ms Debug）；不达标时做块级脏区重解析，不自建 CommonMark |
| TextKit 2 意外降级为 TextKit 1 | P1 | 显式创建；禁止访问 `layoutManager`；开发期监听 fallback 通知并断言 |
| 行内图片破坏源码 1:1 | P1 | MVP 使用悬浮/侧边预览；Phase 2 复用 §4.8 的 fragment 设施 |
| TextKit 2 出现不可绕过的阻塞 | P2 | 兜底是自研排版引擎（§2.1 的 D 路线），代价为重建 IME 与无障碍；决策前先确认阻塞不可 workaround |
| 公式和高亮拖慢首版 | P2 | 保持 Phase 2，不进入 MVP 验收 |

## 08 验证清单

### 正确性

- ASCII、中文、emoji、ZWJ emoji、组合附加符的 range 转换；
- 嵌套/相邻/转义/未闭合 Markdown 标记，并与 AST 做差异测试；
- 列表嵌套深度、有序起始序号、任务框勾选态与 AST 一致；
- CRLF、LF、空文档、超长单行；
- undo/redo 后源码、selection 和渲染一致；
- 源码模式切换不修改文件内容。

### 渲染与绘制

- 块级视觉在**真机窗口**中可见：列表圆点/序号/复选框、引用通宽背景 + 左竖线、代码块通宽背景（含开闭栏行）、分隔线横线；
- 渲染测试经由 `layoutManager` 真实生产的 fragment，而非直接调用绘制函数；
- 嵌套列表各层级缩进与符号有区分；
- 任务 checkbox checked 使用系统 accent 色、unchecked 使用外观感知的 secondary label 色；点击切换 `[ ]`/`[x]` 与一次 undo 属于 M4，当前不宣称已实现；
- 光标进入块内时源码 marker 回显、图形符号让位；
- **暗色模式下逐项检查块视觉配色**（动态色在 fragment 内解析会静默回落亮色，见 §4.8）；
- 系统外观切换后已排版区域的块视觉立即跟随（验证 fragment 缓存不残留旧配色）；
- 文末空行与首帧的块视觉位置正确（对应 FB9856587 / FB15131180 / FB22524198）。

### 交互

- 拼音候选状态、上屏、取消和 Enter；
- marker 前后方向键、鼠标点击和跨 marker 选区；
- 粘贴、多光标不支持时的明确行为、拖放和链接点击；
- VoiceOver 朗读不重复或遗漏正文，隐藏 marker 不制造混乱；
- Reduce Motion、高对比度和系统字体缩放可用。

### 性能与文档生命周期

- 20KB、200KB、1MB 固定语料的输入延迟、AST 解析耗时与样式落地延迟；
- 快速连续输入时旧 revision 不覆盖新内容；
- 打开、保存、Save As、autosave、reopen、外部文件变化与崩溃恢复；
- 多窗口/多文档之间的 text storage、undo manager 和主题状态完全隔离。

---

**下一步：**进入 M3 光标交互：在已收口的 AST/fragment 管线上继续打磨 marker 回显、方向键、鼠标命中与跨行选区；随后在 M4 实现 checkbox 图形命中、源码 `[ ]`/`[x]` 标准文本替换和一次撤销。M2 的历史验收与本轮复查证据见《M2 评价报告》§9.10。

## 参考资料

### Apple

- [What's new in TextKit and text views（WWDC22）](https://developer.apple.com/videos/play/wwdc2022/10090/)
- [Meet TextKit 2（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [TextKit](https://developer.apple.com/documentation/appkit/textkit)
- [NSTextLayoutFragment](https://developer.apple.com/documentation/appkit/nstextlayoutfragment)
- [NSTextLayoutManagerDelegate](https://developer.apple.com/documentation/appkit/nstextlayoutmanagerdelegate)
- [NSTextAttachment](https://developer.apple.com/documentation/appkit/nstextattachment)
- [SwiftUI TextEditor](https://developer.apple.com/documentation/swiftui/texteditor)（macOS 26 的 `AttributedString` 绑定，见 §2.1）

### 解析

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [swift-markdown SourceLocation](https://github.com/swiftlang/swift-markdown/blob/main/Sources/Markdown/Infrastructure/SourceLocation.swift)

### 调研过的替代方案与参考实现（§2.1）

- [STTextView](https://github.com/krzyzanowskim/STTextView) —— TextKit 2 的 text view 替代组件（GPLv3 / 商业双授权，不作为依赖）。其 README 的 **TextKit 2 Bug Reports List** 是本方案 §4.8 缺陷清单的来源。
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) / [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) —— 完全自研排版引擎 + tree-sitter（MIT）。§2.1 的 D 路线。
- [MarkDev](https://github.com/bharathvbcr/MarkDev) —— 自定义 fragment 做 Markdown 块级绘制的先例；§4.8 的动态色隐患线索来自其源码注释。
