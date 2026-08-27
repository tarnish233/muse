# M2 评价报告

- 日期：2026-08-27
- 范围：v0.3 方案 §06 中 M2「解析与渲染」的退出条件
- 结论：**有条件通过（PASS with conditions）**
  - 退出条件的功能项全部达成，78 项测试全绿。
  - 期间存在一个 P0 缺陷（块级视觉完全不可见）与一个 P0 测试缺陷（假绿），**已于 2026-08-27 修复**。
  - 一项架构收口未做（AST 能力未用尽，导致重复实现与语义分叉），**必须在 M3 之前完成**，见 §5。

M2 的退出条件（v0.3 修订后）：`SourceIndex`、AST 语义层、后台 revision 管线；标题、强调、代码、链接；块级视觉绘制地基（自定义 fragment）；单元测试覆盖 Unicode 与未闭合语法。

---

## 1. 交付物

| 交付物 | 位置 | 行数 | 测试 |
|---|---|---:|---|
| UTF-8 ↔ UTF-16 索引 | `Parsing/SourceIndex.swift` | 109 | 8 项 |
| 源码 token 扫描器 | `Parsing/TokenScanner.swift` | 595 | 27 项 |
| swift-markdown 语义层 | `Parsing/MarkdownSemantics.swift` | 191 | 9 项 |
| token 模型 | `Parsing/Token.swift` | 50 | — |
| 渲染引擎（属性层） | `Rendering/RenderEngine.swift` | 517 | 17 项 |
| 块级视觉（绘制层） | `Rendering/BlockLayoutFragment.swift` | 199 | 随渲染测试 |
| 主题 | `Rendering/Theme.swift` | 141 | — |
| 渲染协调器 | `Document/RenderCoordinator.swift` | 194 | 8 项 |
| 性能基准 | `MuseTests/PerformanceTests.swift` | 136 | 5 项 |

**78 项测试 / 7 套件全绿**（Swift Testing）。产品代码 2338 行。

## 2. 达成的部分

- **区间正确性**：`SourceIndex` 在中文、emoji、ZWJ、组合字符、CRLF 下双向转换正确，含落在多字节字符/surrogate 对中间的下取整。
- **后台 revision 管线**：编辑 → revision+1 → 不可变快照 → 后台解析 → 主线程校验 revision → 脏行带增量应用。两轮复审的四个 P1 全部收口（连续编辑丢脏区、光标流用旧 package、换行/围栏重排范围、marker diff 身份），各有回归测试。
- **行内渲染**：标题、粗体、斜体、删除线、行内代码、链接（着色 + 下划线 + `.link` 点击 + 语法隐藏/回显）。嵌套字形特征正确合并（粗体里的斜体得到粗斜体）。
- **marker 三态**：`revealed` / `hidden`（近零宽）/ `ghost`（保留宽度、图形符号让位），显隐按 diff 只写翻转项。
- **渲染与 undo 解耦**：属性写入包在 `disableUndoRegistration` 内，一次撤销 = 文本一步到位。
- **块级视觉绘制地基**：`MuseLayoutFragment` + `MuseLayoutFragmentProvider`（§3 修复后）。

### 性能（Debug 构建，Apple Silicon）

| 项目 | 200KB 实测 |
|---|---:|
| 手写扫描器 + SourceIndex | 8.0 ms |
| swift-markdown 全文档 AST | 64.9 ms |
| 引擎层 `applyDirty`（脏行带重置+重排） | 1.65 ms |
| 协调器端到端（编辑→样式落地） | ~37 ms |

主线程预算（<16ms P95）满足。20KB 的 AST 解析为 6.9 ms。

> Release 数字缺失——测试目标在 Release 下构建失败，见《M1 评价报告》§5.2。这是一个需要修的测量缺口。

## 3. P0 缺陷：块级视觉完全不可见（已修复）

### 现象

M2 期间实现了列表圆点/序号/复选框、引用竖线、引用与代码块通宽背景、分隔线横线。**在真机上一个都画不出来。** 同时属性能表达的部分（字体、颜色、逐字形背景）全部正常。

### 定位过程

1. `.museBlock` 属性写入正确（探针确认 `list:o` / `list:u` / `list:t` / `quote` / `codeFence` 都在位）。
2. 绘制函数确实在跑——加日志后 `drawBackground(in:)` 每帧被调用，fragment 枚举到 21 个、其中 11 个有块类型、11 个走了绘制分支。
3. **决定性实验**：在 `drawBackground(in:)` 里 `super` 之后填一个 300×300 的半透明红块 —— **一个像素都不可见**。

### 根因

layer-backed 的 TextKit 2 `NSTextView` 把字形渲染进各 fragment 自己的图层，视图自身 `draw(_:)` / `drawBackground(in:)` 的输出被整片覆盖。

原实现挂在 `NSTextView.draw(_:)`：先画装饰、再 `super.draw(dirtyRect)`。而 `NSTextView.draw` 的第一步就是用 `backgroundColor` 铺满 dirtyRect——即使不考虑图层问题，先画的内容也会被这一步盖掉。

尝试过的无效修法：

- 改挂 `drawBackground(in:)`（`super` 之后）：仍不可见。
- `textView.wantsLayer = false`：无效。运行时实测仍为 `true`——SwiftUI 宿主视图强制整个子树 layer-backing（见《M1 评价报告》§4）。

### 修复

改为 TextKit 2 官方路径：`MuseLayoutFragment: NSTextLayoutFragment` + `MuseLayoutFragmentProvider: NSTextLayoutManagerDelegate`。文件名 `BlockLayoutFragment.swift` 本来就是这个意思，实现却走了视图级绘制。

修复中确认的四个实现要点（已写入 v0.3 方案 §4.8）：

1. override `draw(at:in:)`，先画装饰再 `super.draw`。
2. **必须 override `renderingSurfaceBounds`** 并 union 到容器宽度，否则通宽背景被裁到字形包围盒。
3. 块归属直接读 `NSTextParagraph.attributedString` 首字符的 `.museBlock`——原实现那套「元素偏移回查 storage + 手写缓存（`museBlockCache` / `museBlockSignature` / `ObjectIdentifier` 追踪 / `hasBlockMarkup` 全文档扫描）」整块删掉了，净减 100+ 行。
4. `draw(at:in:)` 的 `point` 实测恒为 `(0,0)`；容器左边缘 = `point.x - layoutFragmentFrame.minX`；绘制文本需要 `flipped: true` 的 `NSGraphicsContext`。

修复后真机确认：序号 `1.` `2.`、圆点 `•`、复选框 `☑` `☐`、引用通宽背景 + 左竖线、代码块通宽背景（含开闭栏行）、分隔线横线全部正常。78 项测试全绿。

## 4. P0 测试缺陷：假绿（已修复）

这个 P0 缺陷能存活整个 M2，是因为有一个测试在替它作保。

`RendererTests.blockPainterRendersAfterInitialEmptyPaint` 的做法是：建一个位图上下文，**直接调用绘制函数**，数非白像素，断言 `before == 0 && after > 0`。

它一直是绿的。因为直接往 `NSGraphicsContext` 里画当然画得出来——这条路径绕过了真实的 TextKit 图层路径，而真机失效恰恰发生在图层路径上。**测试测的是「绘制函数的算术对不对」，产品需要的是「像素有没有到屏幕上」，两者被混为一谈。**

已改为 `blockVisualsComeFromLayoutFragments`，断言落在两点：

1. `layoutManager` 真实生产的 fragment 里有 `MuseLayoutFragment`（证明委托挂上了）；
2. 经由这些 fragment 的绘制确实落墨（`before == 0`、`after > 0`）。

为此给 `MuseLayoutFragment` 开了一个 `drawBlockVisuals(at:in:)`，把「块视觉落墨」与字形像素分开断言——否则字形会淹没像素差。

**教训**：渲染测试的断言必须落在框架真实产出的对象上。凡是测试里出现「自己构造上下文 + 直接调用绘制函数」的模式，都要怀疑它在测一条产品不走的路径。已写入 v0.3 方案 §07（P1 风险）与 §08（验证清单）。

## 5. 未做的架构收口：AST 能力未用尽（P1，M3 前必须完成）

这是 M2 最实质的问题，也是唯一还没动手的一项。

### 5.1 事实

v0.2 方案 §4.1 假设「AST 只回答内容是什么，不承担精确定位所有 Markdown 标记」，据此立了独立的 `MarkdownTokenScanner`。**这个假设经实测不成立。**

swift-markdown 0.8.0 对所有行内节点都给出精确字节区间：

```text
Strong bytes=0..<10 → "**粗体**"
  Text bytes=2..<8   → "粗体"
```

marker 边界是减法：开标记 = `节点.lower ..< 首子.lower`，闭标记 = `末子.upper ..< 节点.upper`。

而 `TokenScanner.swift` 用 595 行（占 `Parsing/` 945 行的 63%）重新实现了 CommonMark 的 delimiter run 匹配、flanking 判定、mod-3 例外，外加一个塞入数万 CJK 标量的 `CharacterSet`（代码注释自陈「构建约 20–30ms，不能每次扫描重建」）。

实测这些难例 AST 全部已经正确：

| 难例 | AST | 扫描器 |
|---|---|---|
| `***三层星号***` | `Emphasis(Strong(Text))` ✅ | 需 mod-3 规则专门实现 |
| `*a **b** c*` | 反向嵌套 ✅ | **M0 报告 §5 明确记录做不到，「记入 M2」** |
| `**未闭合` | 不成节点、保持 Text ✅ | 需专门的未闭合判定 |
| `\*不是强调\*` | 转义生效 ✅ | 需专门的转义跳过 |
| `**粗体**、` | CJK 邻接正常 ✅ | 需自定义标点集（数万标量） |

### 5.2 已经产生的语义分叉

两套实现同时存在已经分叉了：`a*b*c` 扫描器判为字面量，cmark 判为 `Emphasis`。代码注释把它写成有意设计（「拉丁词内保持字面量」），但它实际是**偏离 CommonMark**，且需要永久维护。

### 5.3 被丢掉的结构信息

`MarkdownSemantics` 只从 AST 提取了三个 `Set<Int>` 行号集合 + 链接区间，用了不到十分之一。实测可直接取用但被丢掉的：

| 信息 | 取法 | 现状 |
|---|---|---|
| 列表嵌套深度 | `ListItem` 父链计数（实测 depth=1/2/3 准确） | 丢弃 → 嵌套不缩进 |
| 有序起始序号 | `OrderedList.startIndex`（实测返回 3） | 丢弃 → 从源码文本抠数字 |
| 任务框勾选态 | `ListItem.checkbox` | 丢弃 → 扫描器自己认 `- [x] ` |
| 代码块语言 | `CodeBlock.language` | 丢弃 → info string 未处理（§6.2） |
| 表格结构 | `Table`/`Head`/`Body`/`Row`/`Cell`，默认选项即解析、全带 source position | 未使用（方案原把表格整体列为 Phase 2） |

嵌套深度的丢失有直接的可见后果——所有列表行拿到完全相同的段落缩进：

```text
line=0  firstIndent=0.0  headIndent=24.0  | 1. 有序列表第一项
line=2  firstIndent=0.0  headIndent=24.0  |    - 无序嵌套…      ← 同一缩进
line=4  firstIndent=0.0  headIndent=24.0  |      - 第三层        ← 同一缩进
```

截图里嵌套那点视觉缩进全部来自源码空格字符本身的宽度，不是排版缩进。

### 5.4 双层设计唯一真实的理由

不是能力，是成本：200KB 上手写扫描器 8.0ms vs 全文档 AST 64.9ms（Debug），约 8 倍。

但解析在后台运行，不占主线程预算，65ms 落在 v0.3 §4.6 新定的样式落地延迟目标（200KB < 150ms）之内。所以顺序应当是**先用全量 AST 把架构简化下来**，只有实测不达标才引入块级脏区重解析（对变化的顶层块单独 `Document(parsing:)`），而不是维护第二套 CommonMark 实现。

已确认 swift-markdown 与 cmark-gfm 都没有增量解析 API（仓库源码层面确认：`incremental` 仅出现在 `BlockDirectiveParser.swift` 与一个计数器测试）。

### 5.5 收口方案

1. `MarkdownSemantics` 输出完整的 marker 区间（父子相减）+ 结构信息（depth / startIndex / checkbox / language）。
2. `Token.Kind` 带上层级与序号：`unorderedListItem(depth:)` / `orderedListItem(depth:number:)`。
3. `Theme.listParagraph(depth:)` 按 depth 计算 `firstLineHeadIndent` / `headIndent`。
4. `TokenScanner` 收缩到只处理未闭合语法（编辑中态），删除 delimiter run / flanking / mod-3 / CJK `CharacterSet`，并消除 `a*b*c` 的语义分叉。
5. 保留 AST 差异测试作为回归网。

## 6. 其他遗留问题

均已精确定位，优先级低于 §5。

### 6.1 代码围栏闭栏行在文档末尾时不并入块样式（P2）

```text
--- 闭栏行在文档末尾 ---
line=2 museBlock=nil   | ```
--- 闭栏行后面还有内容 ---
line=2 museBlock=codeFence | ```
```

根因在 `RenderEngine.applyStyle` 的 `.codeFence` 分支：并入闭栏行依赖 `closeLine + 1 < package.lineStarts.count`，闭栏行是最后一行时该条件为假。现有测试 `blockMarkersCoverLineStarts` 用的源码闭栏行后面还有内容，所以没覆盖到这个边界。

### 6.2 开栏行 info string 与闭栏行标记不隐藏（P2）

光标在围栏块外时逐字符实测（源码 `段落\n\n```swift\nlet a = 1\n```\n\n尾段`）：

```text
[4][5][6] "`"  size=0.1  alpha=0.00  ← 开栏标记正确隐藏
[7..11]  "swift" size=15.0 alpha=1.00 ← info string 可见
[23..25] "`"  size=15.0  alpha=1.00  ← 闭栏标记可见
```

两个独立原因：`token.markerRange` 只覆盖三个反引号，不含 info string；`codeFence` token 的 `closingMarkerRange` 是 `nil`，闭栏标记从未被登记为 marker。这就是截图里 `swift` 单独一行、末尾 ` ``` ` 露在外面的原因。

### 6.3 任务列表 ghost 宽度与图形宽度不匹配（P2，已修复）

```text
任务：ghost '- [x] '=55.6pt  复选框 '☑'=12.5pt  → 空隙 43.1pt
无序：ghost '- '  =18.5pt    圆点 '•'  = 6.8pt  → 空隙 11.7pt
```

`ghost` 状态保留源码 marker 的完整宽度，但绘制的图形符号窄得多，于是符号与文字之间留下大片空白。任务列表尤其明显（43pt）。M2-5 采用推荐的方案 A：列表/任务 marker 统一改为 `hidden`，内容列由 M2-3 的段落缩进承担，图形符号在同一段落 marker 带绘制。新增 `RendererTests.taskAndBulletMarkersAlignToSameContentColumn`，通过真实 TextKit 2 line fragment 的字符位置确认 `- ` 与 `- [ ] ` 的内容起始列一致；全量测试通过。真机截图已保存为 [m2-task-list.png](assets/m2-task-list.png)。

### 6.4 fragment 内解析动态色，暗色模式有风险（P1，已验证机制）

`MuseLayoutFragment` 在 `draw(at:in:)` 里对动态 `NSColor` 取 `.cgColor`。实测该调用按 `NSAppearance.current` 解析，**且 current 为 nil 时不报错、静默回落亮色**：

```text
NSAppearance.current = .aqua     → [0.96, 0.97, 0.98, 1.0]
NSAppearance.current = .darkAqua → [0.15, 0.17, 0.19, 1.0]
NSAppearance.current = nil       → [0.96, 0.97, 0.98, 1.0]
```

两重风险：绘制回调不保证在视图外观上下文里运行；TextKit 按 text element 缓存并复用 fragment，外观切换后未必重绘全部 fragment。

线索来自阅读 `bharathvbcr/MarkDev` 的 `MarkdownLayoutFragment.swift` 源码注释（见 §7）。机制已验证，真机暗色模式表现尚未确认（本轮 GUI 自动化未能稳定拉起窗口）。对策与验收方式已写入 v0.3 方案 §4.8，列入 M3。

### 6.5 引用左竖线的连续性待确认（P3）

真机截图中引用块左侧竖线呈分段而非连续。可能与 fragment 高度 / 行片段划分有关，也可能是截图缩放假象。需要放大核对后再定性。

### 6.6 并行性能基准互相竞争（P2，测试隔离已处理）

M2-1 接入全文档 AST 后，性能套件与其他测试套件并行运行时会竞争 CPU：同一
200KB 协调器路径在默认并行全量运行中曾测得 `136.989042 ms`，而独立串行性能套件
测得 `94.091292 ms`。这是测量环境的竞争，不是通过放宽断言处理；性能套件改为
serialized 后，规格要求的默认全量运行在未降低 `<100 ms` 断言的情况下通过。

### 6.7 MuseKit 抽取后的 Debug App 打包/文档注册问题（P1，已修复）

M1-2 抽取 framework 后，首次直接打开 Debug App 暴露出两个宿主集成问题：App
没有把 `MuseKit.framework` 嵌入 bundle，且 `NSDocumentClass` 仍指向旧的
`Muse.MuseDocument`。前者会导致动态库加载失败，后者会导致 AppKit 报
“No document could be created.”。已将 framework 以 `@rpath` 嵌入并修正为
`MuseKit.MuseDocument`；重新构建后通过真机打开、编辑并显示嵌套列表。该问题不是
静默忽略，修复涉及 `Muse.xcodeproj/project.pbxproj` 与 `Muse-Info.plist`。

## 7. 替代方案调研（2026-08-27）

M2 的绘制层踩坑后做了一次横向调研，确认「自定义 fragment」是否是正确方向，以及是否有现成方案可用。完整结论写入 v0.3 方案 §2.1，此处记要点。

**macOS 26 的 `TextEditor(text: $attributedString)`** —— 确认存在（SDK 26.5 `swiftinterface` 实测），但对 Muse 有三处硬阻塞：`AttributeScopes.SwiftUIAttributes` 无 `paragraphStyle`（列表悬挂缩进无法表达）；`AttributedString` 的 Markdown 只有 `init(markdown:)` 没有导出接口（「保存 = 完整源码」铁律失效）；完全拿不到排版层（块级视觉无法实现）。v0.2 排除 SwiftUI `TextEditor` 的判断正确，现在有了具体依据。

**STTextView** —— TextKit 2 的 text view 替代组件，架构与 Muse 修复后落地的方案一致（`STTextLayoutFragment` + `NSTextLayoutManagerDelegate` + fragment view），是对方向的独立印证。GPLv3 / 商业双授权，不引入为依赖。其 README 维护的 TextKit 2 缺陷清单价值很高——作者明确说该项目存在的原因就是「NSTextView + TextKit 2 并不完全可用，被具体 bug 阻塞后才另起项目」。与 Muse 直接相关的条目（FB9692714 渲染属性绘制异常、FB9856587 多余末行 fragment、FB15131180 / FB22524198 extra line fragment 尺寸与私有 API）已录入 v0.3 §4.8。另注意其 fragment 在 `state < .layoutAvailable` 时通过混淆 selector 调用私有 `layout`，作者注明「没有公开 API 提供这个能力」——说明「绘制时 fragment 尚未排版」是 TextKit 2 的真实缺口。

**CodeEditTextView / CodeEditSourceEditor** —— 完全自研排版引擎，不用 TextKit（自建 `TextLayoutManager` / `TextLineStorage` / `TextLine` / `TextSelectionManager` / `MarkedTextManager`），MIT。其 README 明确：需要「右到左文本、自定义布局元素、与系统 text view 功能对等」的应当用 STTextView 或 `NSTextView`——这三项正是 Muse 的需求，所以不适用。但它是一个值得记住的数据点：严肃的开源编辑器项目评估 TextKit 后选择自研。作为 TextKit 2 出现不可绕过阻塞时的兜底路线记入 v0.3 §07（P2）。

**自定义 fragment 做 Markdown 渲染已有先例** —— `nodes-app/swift-markdown-engine`、`no-problem-dev/swift-markdown-view`、`bharathvbcr/MarkDev` 都有同名的 `MarkdownLayoutFragment`，MarkDev 的注释写明「Custom drawing behind code blocks, callouts, quotes, and rules」。§6.4 的隐患线索即来自其源码。

## 8. 评价

M2 交付的管线质量是高的：后台 revision + 脏行带增量 + 显隐 diff 三层经过两轮复审、每个 P1 都有回归测试，200KB 主线程 1.65ms 这个数字说明增量策略是真的在工作。区间层（`SourceIndex`）在 Unicode 边界上的严谨程度也超出里程碑要求。

问题集中在两处，性质不同：

**绘制层的失效（§3、§4）是流程问题。** 缺陷本身修起来不难——换一条 API 路径、净减 100 行代码。真正的问题是它能存活整个里程碑，而这由两件事共同造成：v0.2 方案把 fragment 判为「Phase 2 可选」，以及一个绕过真实路径的测试持续作保。前者已在 v0.3 §4.8 纠正，后者的教训（「渲染断言必须落在框架真实产出的对象上」）已写入验证清单。

**AST 能力未用尽（§5）是判断问题，且尚未收口。** M2 名义上引入了 swift-markdown，实际只用它做链接锚点和三个行号集合，同时用 595 行手写代码重新实现了 AST 已经做对的事——包括 M0 报告明确承认扫描器做不到、要「记入 M2」解决的反向嵌套。M2 结束时这一项既没做，也没有重新评估「为什么需要第二套实现」。

这是本报告把结论定为「有条件通过」的原因：功能达标、测试全绿，但解析层带着一份 595 行的重复实现和一处已知语义分叉进入下一个里程碑，而列表嵌套这个 MVP 明确要求的功能因此无法实现。**§5.5 的收口必须在 M3 开始前完成**，否则 M3 的光标交互会建在一个需要重写的解析层上。

**方法上的一条收获：** 这一轮所有结论都来自可复现的探针（AST 区间打印、逐字符属性 dump、像素落墨实验、动态色解析对比），而不是读代码推断。§3 的根因、§5.1 的能力对比、§6.1–6.4 的边界，都是先写探针拿到数据再下判断——其中 §5.1 直接推翻了方案沿用两个版本的核心假设，§6.4 找出了一个刚写完的代码里的隐患。**在这类「框架行为不确定」的领域，实测的信息量远高于代码审阅。**

---

## 9. 接下来要做什么（M2 收口）

**全局约束见《M0 评价报告》§9.1，开工前必须先读。** 其中第 3 条（渲染测试必须走框架真实产出的对象）是本里程碑最重要的教训，违反它等于把 §4 的缺陷再造一遍。

**执行顺序有依赖，不要打乱：**

```text
M2-1（AST 收口：语义层输出）
  └─ M2-2（Token 带 depth/number）
       └─ M2-3（列表嵌套缩进）
       └─ M2-5（ghost 宽度）
  └─ M2-4（扫描器收缩）        ← 依赖 M2-1 完成且 M2-2/3 已验证
M2-6（闭栏行 EOF）              ← 独立，可随时做
M2-7（info string / 闭栏标记隐藏）← 独立，可随时做
M2-8（动态色调色板）            ← 独立，可随时做
M2-9（引用竖线连续性）          ← 独立，先定性再决定是否修
```

建议先做独立项（M2-6/7/8）建立信心，再动 M2-1 这条主线。

### 9.1 任务 M2-1：语义层输出完整 marker 区间与结构信息

**现状**：`Parsing/MarkdownSemantics.swift` 只对外暴露 `lineKinds`、`links`、`listItemLines`、`quoteLines`、`fenceLines`——三个行号 `Set` 加链接区间，AST 能力用了不到十分之一。

**关键事实（已实测，可复现）**：swift-markdown 0.8.0 对所有行内节点都给出精确 UTF-8 字节区间，marker 边界是减法：

- 开标记 = `节点.range.lower ..< 首子.range.lower`
- 闭标记 = `末子.range.upper ..< 节点.range.upper`

例：源码 `**粗体**` → `Strong bytes=0..<10`、子 `Text bytes=2..<8` → 开标记 `0..<2`、闭标记 `8..<10`。

`SourceRange` 是 1-based 行列，字节偏移 = `lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1`。`MarkdownSemantics.collectLinkRanges` 已有这个换算，照它写。

**要做**：给 `MarkdownSemantics` 增加输出。建议结构（可调整，但信息必须齐）：

```swift
/// AST 推导出的行内标记（marker 由父子区间相减得到）
struct InlineMarker: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case strong, emphasis, inlineCode, strikethrough }
    let kind: Kind
    let openMarker: Range<Int>
    let closeMarker: Range<Int>
    let content: Range<Int>
    let line: Int
}

/// AST 推导出的块级结构
struct BlockStructure: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case unorderedList(depth: Int)
        case orderedList(depth: Int, number: Int)
        case taskList(depth: Int, checked: Bool)
        case blockquote(depth: Int)
        case codeFence(language: String?)
    }
    let kind: Kind
    let line: Int
    /// 行首到内容起点的 marker 区间（含缩进后的标记字符与其后空格）
    let marker: Range<Int>
}

let inlineMarkers: [InlineMarker]
let blocks: [BlockStructure]
```

各项信息的取法（全部已实测可用）：

| 信息 | 取法 | 实测结果 |
|---|---|---|
| 列表嵌套深度 | `ListItem` 的 `parent` 链中 `UnorderedList`/`OrderedList` 计数 | `- 一层/  - 二层/    - 三层` → depth 1/2/3 |
| 有序起始序号 | `OrderedList.startIndex`（`UInt`），项内序号 = start + 项在列表内的下标 | `3. / 4.` → `startIndex = 3` |
| 任务勾选态 | `ListItem.checkbox`（`.checked` / `.unchecked` / `nil`） | `- [x]` → `Optional(Checkbox.checked)` |
| 代码块语言 | `CodeBlock.language` | ` ```swift ` → `"swift"` |
| 引用嵌套深度 | `BlockQuote` 的 parent 链中 `BlockQuote` 计数 | — |

**这些难例 AST 已经正确，不要为它们写任何补丁逻辑**：`***三层星号***`（→ `Emphasis(Strong(Text))`）、`*a **b** c*`（反向嵌套）、`**未闭合`（不成节点、保持 Text）、`\*不是强调\*`（转义生效）、`**粗体**、`（CJK 邻接正常，**不需要自定义标点集**）。

**要做的第二件事**：`RenderEngine.prepare` 里的 `needsMarkdownSemantics(source)` 短路判断必须**删除**。它现在只在源码含 `[` 或有 >3 空格/tab 缩进时才跑 AST，导致「2 空格缩进的嵌套列表 + 无链接」的文档根本不调用 swift-markdown。收口后 AST 是唯一语义来源，必须每次都跑。

**验收**：

1. 新测试 `MuseTests/MarkdownSemanticsTests.swift`：
   - `inlineMarkersMatchByteBoundaries`：对 `**粗体**、*斜体*、~~删除线~~ 与 \`行内代码\`` 断言四个 marker 的 open/close/content 字节区间精确值
   - `nestedEmphasisMarkersFromAST`：对 `**粗体里的 *斜体* 与 \`代码\`**` 与 `***三层星号***` 断言嵌套 marker 正确
   - `reverseNestedEmphasisFromAST`：对 `*a **b** c*` 断言——**这一项是 M0 报告 §5 明确记录扫描器做不到的**，AST 必须做对
   - `unclosedEmphasisProducesNoMarker`：`**未闭合` 不产出 marker
   - `listDepthAndNumberFromAST`：三层嵌套断言 depth 1/2/3；`3. / 4.` 断言 number 3/4
   - `taskCheckboxFromAST`：`- [x]` / `- [ ]` 断言勾选态
   - `codeFenceLanguageFromAST`：` ```swift ` 断言 `language == "swift"`
2. 新测试 `nestedListWithoutLinksStillUsesAST`：源码为 2 空格缩进的嵌套列表且**不含 `[`**，断言 depth 信息存在（守护 `needsMarkdownSemantics` 已删除）
3. 全量测试仍全绿

**不要在这个任务里动 `TokenScanner`**。M2-1 只是让语义层把信息**输出**出来，消费和删除旧实现分别是 M2-2 和 M2-4。这样每一步都可独立回滚。

**完成记录（2026-08-27）**：已完成。`MarkdownSemantics` 现在通过单次
`swift-markdown` AST 遍历输出行内 marker 的 UTF-8 区间、块结构的 depth/number/
checkbox/language，并继续提供链接与结构行集合；`RenderEngine.prepare` 已删除
`needsMarkdownSemantics` 短路，每次快照都会构建语义层。新增的 8 项 M2-1 语义测试与
全量 **97 项 / 7 套件**测试通过。Debug 性能套件中 200KB 协调器单键路径串行实测
`94.091292 ms`；性能套件已标为 serialized，避免并行基准的 CPU 竞争污染端到端测量，
没有改变任何阈值或跳过测试。

### 9.2 任务 M2-2：Token 携带层级与序号

**现状**：`Parsing/Token.swift` 的 `Token.Kind` 是：

```swift
case unorderedListItem
case orderedListItem
case taskListItem(checked: Bool)
case blockquote
```

没有 depth，没有 number。渲染层因此拿不到层级——探针实测三层嵌套的 token 完全无法区分：

```text
line=2 kind=unorderedListItem   ← 第二层
line=4 kind=unorderedListItem   ← 第三层，与上面同值
```

**要做**：

```swift
case unorderedListItem(depth: Int)
case orderedListItem(depth: Int, number: Int)
case taskListItem(depth: Int, checked: Bool)
case blockquote(depth: Int)
```

depth 从 1 起（最外层 = 1）。在 `RenderEngine.prepare` 中用 M2-1 的 `blocks` 信息填充。

**注意**：`Token.isBlockMarker` 与 `RenderEngine` 里所有 `switch token.kind` 都要跟着改。`Rendering/RenderEngine.swift` 的 `defaultState(_:)`、`applyStyle(_:package:into:)`、`quoteLines(of:)`、`fenceRanges(of:)` 都有模式匹配。`Rendering/BlockLayoutFragment.swift` 的 `glyphText(kind:info:)` 目前从源码文本抠数字（`info.markerText.prefix { $0.isNumber }`），改为消费 token 的 `number`。

**验收**：

1. `MuseTests/TokenScannerTests.swift` 或新建测试：`listTokensCarryDepth`——三层嵌套断言 token 的 depth 为 1/2/3
2. `orderedListTokensCarryNumber`——`3. / 4.` 断言 number 为 3/4；`1. / 2.` 断言 1/2
3. 全量测试全绿（改枚举会牵动很多处，这一步的重点是不回归）

**完成记录（2026-08-27）**：已完成。`Token.Kind` 现在携带列表/引用的 AST
`depth`，有序列表同时携带 `number`；`RenderEngine.prepare` 将
`MarkdownSemantics.blocks` 的结构信息写回 token，并通过 `museListNumber` 属性供
真实布局 fragment 绘制有序 marker，绘制层不再从源码抠序号。新增
`listTokensCarryDepth`、`orderedListTokensCarryNumber` 测试；全量 **99 项 / 7 套件**
测试通过。

### 9.3 任务 M2-3：列表嵌套层级缩进（MVP 明确要求的功能）

**现状**：`Rendering/Theme.swift` 的 `listParagraph()` 无参数，返回固定值。实测所有层级拿到完全相同的缩进：

```text
line=0  firstIndent=0.0  headIndent=24.0  | 1. 有序列表第一项
line=2  firstIndent=0.0  headIndent=24.0  |    - 无序嵌套…      ← 同一缩进
line=4  firstIndent=0.0  headIndent=24.0  |      - 第三层        ← 同一缩进
```

真机截图里嵌套那点视觉缩进全部来自源码空格字符本身的宽度，不是排版缩进。对照 Typora，嵌套层级应有明显的阶梯缩进。

**要做**：

1. `Theme.listParagraph(depth: Int)`：`firstLineHeadIndent = CGFloat(depth - 1) * 24`，`headIndent = CGFloat(depth) * 24`（悬挂缩进：换行对齐内容列）。具体数值可调，但必须随 depth 递增。
2. `RenderEngine.applyStyle` 的列表分支传入 token 的 depth。
3. `BlockLayoutFragment.MuseLayoutFragment.drawListMarker` 的图形符号 x 坐标要跟上缩进——目前用 `info.leadingWidth`（源码前导空白的宽度），改为按段落缩进定位，否则符号和文字会错位。
4. `glyphText` 的无序符号分级目前按 `info.indentationUnits / 2` 猜层级，改为用 token 的 depth。

**验收**：

1. `RendererTests.listParagraphIndentScalesWithDepth`：三层嵌套断言三行的 `firstLineHeadIndent` / `headIndent` 严格递增
2. `nestedListMarkersAlignWithIndent`：经真实 fragment 断言各层符号的绘制 x 坐标随 depth 递增
3. **真机截图核对**：打开示例文档，确认嵌套列表呈阶梯缩进、符号与文字对齐、三层符号分别为 `•` `◦` `▪`。截图存到 `docs/assets/m2-nested-list.png` 并在本报告 §6 引用
4. 现有 `listParagraphHasHangingIndent` 测试会失败（它断言 `headIndent == 24`），改为断言 depth 1 的值

**完成记录（2026-08-27）**：已完成。列表段落样式按 AST 携带的 depth 使用 24pt
阶梯缩进，列表 fragment 的 marker 带随实际段落缩进定位，并按 depth 绘制
`•`/`◦`/`▪`。新增 `listParagraphIndentScalesWithDepth` 与
`nestedListMarkersAlignWithIndent`；Debug 全量 **101 项 / 7 套件**测试通过。
真机截图已保存为 [m2-nested-list.png](assets/m2-nested-list.png)，确认三层列表呈阶梯
缩进且符号与内容列对齐。

### 9.4 任务 M2-4：收缩 TokenScanner 到只处理未闭合语法

**这一项风险最高，务必在 M2-1/2/3 全部验收通过后再做。**

**现状**：`Parsing/TokenScanner.swift` 595 行（占 `Parsing/` 945 行的 63%），其中重新实现了 CommonMark 的：

- delimiter run 匹配（`scanStarRuns`、`StarRun`）
- flanking 判定（`charClass`、`CharClass`）
- mod-3 例外（`mod3OK`）
- 一个塞入数万 CJK 标量的 `punctuationSet`（代码注释自陈「构建约 20–30ms，不能每次扫描重建」）

**并且已经产生语义分叉**：`a*b*c` 扫描器判为字面量，cmark 判为 `Emphasis`。注释把它写成有意设计（「拉丁词内保持字面量」），但它是偏离 CommonMark。

**要做**：

1. 删除 `scanStarRuns`、`StarRun`、`mod3OK`、`scanStrikethrough`、`scanCodeSpans`、`charClass`、`CharClass`、`punctuationSet`、`whitespaceSet`、`utf8SequenceLength`、`findRun`、`findSequence`、`runLength` 中所有仅服务于强调/删除线/行内代码匹配的部分——这些能力由 M2-1 的 AST 输出接管。
2. 保留：`lines(_:)`（行结构，`RenderEngine` 和 `MarkdownSemantics` 都依赖）。
3. 保留并收窄职责：**未闭合语法的编辑中态识别**。AST 按 CommonMark 定义不为 `**未闭合` 生成节点（这是正确行为），但编辑器需要知道「这里正在输入一个粗体」以决定 marker 显隐。这是唯一需要字节级扫描的场景。
4. 块级扫描（`scanBlockAndInline` 里的标题/列表/引用/围栏/分隔线定位）也由 M2-1 的 `blocks` 接管，一并删除。
5. **消除 `a*b*c` 分叉**：删除后行为自动与 cmark 一致，需更新对应测试的期望值并在注释说明这是修正而非回归。

**验收**：

1. `Parsing/TokenScanner.swift` 行数 **< 150 行**（当前 595）
2. `Parsing/TokenScanner.swift` 中不再出现 `flanking`、`mod3`、`punctuationSet`、`StarRun` 等标识
3. 现有 `TokenScannerTests.swift` 的 27 项：与 CommonMark 一致的断言必须继续通过；`a*b*c` 那一项改为断言产出 emphasis，并注明「修正 v0.2 的语义分叉，与 cmark 对齐」
4. **AST 差异测试保留为回归网**：`MarkdownSemanticsTests` 中对比「AST 结果 vs 渲染结果」的测试必须全绿
5. 全量测试全绿，且真机截图确认行内渲染（粗体/斜体/删除线/行内代码/嵌套/三层星号）无视觉回归

**若中途发现 AST 无法覆盖某个场景**：不要重新加回扫描逻辑，先停下来把该场景写成一个失败测试并记录在本报告 §6，由人决策。这是防止「双层实现」以补丁形式复活的闸门。

### 9.5 任务 M2-5：任务列表 ghost 宽度与图形宽度对齐

**现状**（实测数值）：

```text
任务：ghost '- [x] '=55.6pt  复选框 '☑'=12.5pt  → 空隙 43.1pt
无序：ghost '- '  =18.5pt    圆点 '•'  = 6.8pt  → 空隙 11.7pt
```

`ghost` 状态（`RenderEngine.markerVisibilityAttributes(state:)` 的 `.ghost` 分支）保留源码 marker 的完整宽度（`revealedMarkerFont()` = 15pt mono），但绘制的图形符号窄得多，符号与文字之间留下大片空白。任务列表尤其明显。

**要做**：两条路选一条，写下选择理由。

- **方案 A（推荐）**：marker 改用 `hidden`（近零宽），对齐完全交给段落缩进（M2-3 的 `firstLineHeadIndent`），图形符号按段落缩进定位绘制。这样源码 marker 长度不再影响布局，`- [x] ` 和 `- ` 的视觉缩进一致。
- **方案 B**：保留 `ghost` 但按图形符号实际宽度设置字号，使 ghost 宽度 ≈ 符号宽度。实现简单但仍受源码 marker 字符数影响，`- [x] ` 与 `- ` 会不一致。

**验收**：

1. `RendererTests.taskAndBulletMarkersAlignToSameContentColumn`：断言任务列表行与无序列表行（同 depth）的内容起始 x 坐标相同
2. 真机截图：复选框/圆点与文字的间距视觉一致，无大片空白
3. 若选方案 A，`markerVisibilityAttributes` 的 `.ghost` 状态可能整体不再需要——若确实如此，一并删除并更新 `MarkerState` 枚举与 v0.3 方案 §4.2 的三态表格

**完成记录（2026-08-27）**：已完成，选择方案 A。列表/任务 marker 统一使用近零宽
`hidden` 状态，删除 `MarkerState.ghost` 及对应三态文档；内容列由现有列表段落缩进
提供，fragment 将替代图形绘制在内容字形左侧，并扩展 fragment surface 防止被 TextKit
裁切。新增 `taskAndBulletMarkersAlignToSameContentColumn`，经真实 TextKit 2 line
fragment 断言两种 marker 的内容起始列一致；Debug 全量 **102 项 / 7 套件**测试通过。
真机截图已保存为 [m2-task-list.png](assets/m2-task-list.png)，确认圆点/复选框与文字
间距一致且无 ghost 宽度造成的大空白。

### 9.6 任务 M2-6：代码围栏闭栏行在文档末尾时不并入块样式

**现状**（可复现）：

```text
--- 闭栏行在文档末尾 ---
line=2 museBlock=nil        | ```
--- 闭栏行后面还有内容 ---
line=2 museBlock=codeFence  | ```
```

**根因**：`Rendering/RenderEngine.swift` 的 `applyStyle` 中 `.codeFence` 分支：

```swift
if let contentEnd = token.contentRange?.upperBound, contentEnd < package.index.utf8Length {
    let closeLine = lineIndex(atUTF8: contentEnd, package: package)
    if closeLine + 1 < package.lineStarts.count {
        upper = max(upper, package.lineStarts[closeLine + 1])
    }
}
```

两个条件都会在「闭栏行是最后一行」时把闭栏行排除：外层 `contentEnd < utf8Length` 和内层 `closeLine + 1 < lineStarts.count`。

现有测试 `RendererTests.blockMarkersCoverLineStarts` 用的语料闭栏行后面还有内容，所以没覆盖这个边界。

**要做**：修正边界，闭栏行是最后一行时 `upper` 取 `package.index.utf8Length`。

**验收**：

1. `RendererTests.closingFenceAtEndOfDocumentGetsBlockAttribute`：源码 ` ```swift\nlet a = 1\n``` `（无尾随换行），断言闭栏行行首的 `.museBlock == BlockVisual.codeFence.rawValue`
2. 同时保留「闭栏行后有内容」的既有断言不回归
3. 补一个「未闭合围栏延伸到文档末尾」的断言（`TokenScanner` 有这个分支，渲染侧应确认块属性覆盖到末尾）

### 9.7 任务 M2-7：开栏行 info string 与闭栏行标记未隐藏

**现状**（光标在围栏块外，源码 `段落\n\n```swift\nlet a = 1\n```\n\n尾段`，逐字符实测）：

```text
[4][5][6] "`"     size=0.1   alpha=0.00  ← 开栏标记正确隐藏
[7..11]   "swift" size=15.0  alpha=1.00  ← info string 可见
[23..25]  "`"     size=15.0  alpha=1.00  ← 闭栏标记可见
```

两个独立原因：

1. `token.markerRange` 只覆盖三个反引号，不含 info string ——见 `TokenScanner.scanFenceMarker` 返回的 `runStart..<i`
2. `codeFence` token 的 `closingMarkerRange` 是 `nil`，闭栏标记从未被登记为 marker ——见 `TokenScanner.scan` 里闭合围栏时只更新 `contentRange`

这就是真机截图里 `swift` 单独占一行、文末 ` ``` ` 露在外面的原因（对照 Typora：两者都应隐藏，语言标识可作为角标或完全不显示）。

**要做**：

1. marker 区间扩展到含 info string（` ```swift ` 整段）
2. 闭栏标记登记为 `closingMarkerRange`，随块显隐规则一起隐藏/回显
3. 语言标识的呈现方式：MVP 阶段先隐藏即可（语法高亮是 Phase 2）。若要显示，用 M2-1 的 `CodeBlock.language` 在绘制层画角标，**不要**靠源码字符显示

**验收**：

1. `RendererTests.fenceInfoStringAndCloserHiddenWhenCaretOutside`：光标在围栏块外时，断言开栏三反引号、info string、闭栏三反引号全部为隐藏状态（字号 < 1 或 alpha == 0）
2. `fenceMarkersRevealedWhenCaretInside`：光标在围栏块内时三者全部回显
3. 真机截图确认代码块上下边缘干净，无 `swift` 与 ` ``` ` 残留

### 9.8 任务 M2-8：块视觉配色改共享调色板（修暗色模式隐患）

**现状**：`Rendering/BlockLayoutFragment.swift` 的 `drawDecoration` 与 `drawListMarker` 在绘制时对动态 `NSColor` 取 `.cgColor`（如 `theme.quoteBackground.cgColor`）。实测该调用按 `NSAppearance.current` 解析，**且 current 为 nil 时不报错、静默回落亮色**：

```text
NSAppearance.current = .aqua     → [0.96, 0.97, 0.98, 1.0]
NSAppearance.current = .darkAqua → [0.15, 0.17, 0.19, 1.0]
NSAppearance.current = nil       → [0.96, 0.97, 0.98, 1.0]
```

两重风险：

1. fragment 的绘制回调不保证运行在视图的外观上下文里 → 暗色模式画成亮色
2. TextKit 按 text element 缓存并复用 fragment，外观切换后未必重绘全部 fragment → 残留旧外观配色

**要做**：不在 fragment 内解析动态色。改为一份**共享的、已解析的 `CGColor` 调色板**：

- 单一实例（不是每个 fragment 各持一份副本——副本会比它被解析时的外观活得更久，而且没有任何遍历能保证触达全部存活 fragment）
- 外观变化时**整体替换实例内容**，这样每个 fragment 无论是否在屏上，绘制那一刻读到的都是当前值
- fragment 回调早于 actor 标注、可能从任意上下文调用，读写用锁保护而不是依赖 MainActor 隔离
- 外观变化的监听点：`EditorTextView.viewDidChangeEffectiveAppearance()`

参考实现思路见 `bharathvbcr/MarkDev` 的 `MarkdownLayoutFragment.swift` 源码注释（该隐患的线索即来自那里）。

**同时要做**：`Rendering/Theme.swift` 目前标了 `@unchecked Sendable` 并持有 `NSColor`。调色板落地后重新评估这个标注是否还需要——理想状态是 fragment 只依赖已解析的 `CGColor`，不再需要跨隔离域传 `NSColor`。

**验收**：

1. 《M0 评价报告》§9.3 的 `blockVisualsFollowAppearance` 测试转绿并移除 `withKnownIssue`
2. 新测试 `paletteUpdatesOnAppearanceChange`：切换外观后断言调色板实例的内容已更新
3. **真机验证**（M0 §9.4 的第 12、13 项）：暗色模式下块视觉配色正确；App 打开时热切换系统外观，已排版区域立即跟随，不需要滚动或编辑触发
4. 在本报告 §6.4 回填「真机确认：通过」

### 9.9 任务 M2-9：引用块左竖线连续性定性

**现状**：真机截图中引用块左侧竖线呈分段而非连续。可能原因：fragment 高度与行片段划分不一致；或仅是截图缩放假象。

**要做**：先定性再决定是否修。

1. 用多行引用块（含软换行的长行 + 多个 `>` 行）截图，放大到 1:1 像素核对
2. 若确认分段：检查 `drawDecoration` 的 `.quote` 分支中竖线高度用的 `layoutFragmentFrame.height` 是否覆盖了 fragment 的全部行片段；多段 `>` 行会产生多个 element/fragment，段间可能有 `paragraphSpacing` 间隙需要填充
3. 若是假象：在本报告 §6.5 记录「已核对，非缺陷」并结束

**验收**：本报告 §6.5 有明确定性结论（缺陷 + 修法，或非缺陷）；若是缺陷则修复并补真机截图。

### 9.10 M2 的结论如何更新

**收口完成的判据**（全部满足才能把结论从「有条件通过」改为「通过」）：

1. M2-1 到 M2-8 全部验收通过（M2-9 允许结论为「非缺陷」）
2. `Parsing/TokenScanner.swift` < 150 行，且不含 CommonMark 匹配逻辑
3. `RenderEngine.prepare` 中 `needsMarkdownSemantics` 短路已删除
4. 列表嵌套在真机上呈阶梯缩进，三层符号有区分
5. 暗色模式与外观热切换下块视觉配色正确
6. 全量测试全绿，且测试数不低于当前 78 项
7. 本报告 §5「未做的架构收口」改写为「已收口」，附收口前后的行数与语义分叉对比

**只要第 2 条或第 3 条未达成，结论必须保持「有条件通过」**——那意味着解析层仍带着重复实现进入 M3，而这正是本报告给出条件结论的原因。

### 9.11 交付要求

- 每个任务一个独立 commit，message 用 `M2-N: <做了什么>` 格式，便于逐项回滚
- 涉及视觉的任务（M2-3、M2-5、M2-7、M2-8、M2-9）必须附真机截图，存到 `docs/assets/`
- 任务过程中发现的新问题追加到本报告 §6，不要静默处理
- 若某任务的验收标准无法满足，**停下来记录原因**，不要降低标准或跳过——本报告的价值在于它记录的是实测事实，不是意图
