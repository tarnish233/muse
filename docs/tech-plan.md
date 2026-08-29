# Muse 技术方案

一款极简即时渲染 Markdown 编辑器（对标 Typora），纯 macOS 原生实现。

- 版本：v0.9 · 2026-08-28
- 目标平台：macOS 14+
- 技术栈：Swift 6 · AppKit（TextKit 2）· SwiftUI · swift-markdown

> **v0.3 修订说明**：v0.2 的技术路线（NSTextView + TextKit 2 + swift-markdown）经 M0–M2 验证成立，保持不变。但 v0.2 对两个关键事实的判断是反的，v0.3 予以纠正；同时补入一次替代方案调研：
>
> 1. **swift-markdown 的能力被低估**。v0.2 §4.1 假设「AST 不承担精确定位所有 Markdown 标记」，据此立了一个独立的完整 tokenizer。实测 AST 对所有行内节点都给出精确字节区间，marker 位置可由父子区间相减得到，且 `***`、反向嵌套、未闭合、转义、CJK 邻接等难例全部已经正确。
> 2. **`NSTextLayoutFragment` 的必要性被推迟**。v0.2 §02/§4.2 把它列为「必要时」「Phase 2 再评估」。实测在 layer-backed 的 TextKit 2 `NSTextView` 上，视图级 `draw(_:)` / `drawBackground(in:)` 的输出会被完全覆盖——自定义 fragment 是任何块级视觉的唯一入口，属于 MVP 地基而非后续优化。
> 3. **替代方案已实测排除**（新增 §2.1）。macOS 26 的 `TextEditor(text: $attributedString)`、STTextView、CodeEditTextView 三条路线逐一核验，结论是继续走 A 方案；细节与依据见 §2.1。
>
> 详见 §2.1、§4.1、§4.2、§4.9 与《M2 评价报告》。

> **v0.4 工作区修订说明**：SwiftUI 外壳不再展示“假项目 + 当前文稿”静态列表，改为 Codex 风格的真实目录工作区。三列布局、侧栏表面、宽度、分隔线与开合状态均由 Muse 自己控制，不使用 `NavigationSplitView`、系统 sidebar `List` 或 `.inspector`；左侧项目可展开为文件树，并支持新建项目、打开项目、在项目或任意文件夹中新建文件/文件夹。文件与文档生命周期仍优先使用 macOS 官方 API，详见《工作区与侧栏重构报告》及 §3.1。

> **v0.5 阶段审计说明**：2026-08-28 按当前代码重新核对 M0–M2。Debug 与 Release 均为 **115 tests / 8 suites 全绿**；Release 200KB 协调器单键路径为 71.256ms，低于 150ms 样式落地目标。M1、M2 正式通过；M0 的工程实现和自动化已完成，但 M0-3 的 IME、VoiceOver、零宽 marker 等人工 gate 尚未完整回填，因此正式状态修正为“有条件通过”。详见《M0–M2 阶段完成情况报告》。

> **v0.6 M3 收口说明**：M3 光标交互已完成。方向键、鼠标命中和选区继续由系统 `NSTextView` 处理，Muse 只根据系统选区更新 marker 派生属性；跨行选择现在会回显所有相交块的源码 marker。新增同一 `NSTextStorage` 上的源码模式，可通过“显示 → 源码模式”或 `⌘/` 切换，切换不改字符、不标脏、不进入 undo，并在输入法 marked text 期间延后属性更新。Debug、Release 均为 **120 tests / 8 suites 全绿**；真实窗口已验证方向键穿越 marker、鼠标命中、跨行选择、源码编辑与撤销。详见《M3 光标交互报告》。

> **v0.7 M4 块行为说明**：列表 Enter 支持续项（任务项继承原 `[ ]`/`[x]` 及大小写、有序项沿用原源码序号、空项退出）；**标题内容起点 Enter 在标题上方插入空段落**并把光标留在那里，标题本体完整保留，空标题则退出标题；`*`、`**`、反引号采用保守自动配对，并尊重选区、转义、已有闭合符与 marked text。任务 checkbox 复用真实 `NSTextLayoutFragment` 绘制几何完成命中，并通过 `NSTextView` 标准文本替换切换 `[ ]`/`[x]`。
>
> Enter 由 `EditorTextView.insertNewline(_:)` 覆写接管（不再走 delegate 的 `doCommandBy`），⌥Return / ⌃O / ⌃Return 一律插入普通 `\n` 且不续行，作为「只要一个干净换行」的逃生舱；⌃Return 尤其必须覆写——`NSTextView` 原生实现插入的是 U+2028，cmark 不认它是换行。
>
> 块上下文取自渲染属性（`.museBlock` 及列表 marker 属性）；属性尚未落地时回退到 **swift-markdown 的单行解析**（`MarkdownSemantics.lineBlockKind`，实测 14µs），不自己实现行级 CommonMark 规则。
>
> 本批没有引入新依赖，继续使用 AppKit/TextKit 2 与现有 swift-markdown；**164 tests / 9 suites 全绿**。M4 保持"进行中"，下一批继续处理围栏输入细节并执行 IME、真实窗口与 VoiceOver 人工验收。

> **v0.8 M4 第二批说明**：反引号自动配对现可从单反引号逐次升级为任意长度的成对 delimiter；用反引号包裹选区时，会按选区内最长连续反引号 run 加一，选择最短且不会与内容冲突的 CommonMark delimiter。只有 Muse 刚创建且内容仍为空的 pair 才允许升级；已有源码中的反引号不会被吞键。
>
> 代码围栏回归覆盖三反引号、四反引号和波浪线围栏（含 info string），围栏体内形似列表的行始终走原生换行，不注入列表 marker。列表回归新增多层缩进、引用内任务项和连续有序列表场景；有序项继续沿用当前源码序号，不重排后续兄弟项。自动化同时覆盖 list / pair / checkbox 的 redo、marked-text 期间智能换行回退，以及可访问文本保持完整 Markdown 源码。
>
> 本批仍不引入新依赖；全量 **180 tests / 10 suites 全绿**。M4 的可自动化行为已补齐，阶段仍保持“进行中”，剩余 gate 是在真实中文输入法、真实窗口 checkbox 点击和 VoiceOver 朗读中做人工验收并回填结果。

> **v0.9 连续输入渲染管线说明**：删除 `editsSinceApply > 1` 的整篇装饰兜底。`RenderCoordinator` 现在把 pending dirty range 始终维护在当前正文的 UTF-16 坐标系：前方插入会平移旧范围，重叠删除会收缩范围，多处编辑会合并；只有当前 revision 成功应用后才清空 pending 状态，`lastPackage` 与 `appliedRevision` 同步成为属性层权威来源。
>
> 进一步实测发现 swift-markdown 的同步 `prepare` 不合作响应 Task cancellation：连续按键若立即启动 detached task，会留下多个已取消但仍占 CPU 的整篇解析。管线新增 8ms 输入 burst 去抖，在进入 `prepare` 前合作取消，零间隔 11 键只启动 1 次最新快照解析。
>
> 新增 6 项坐标、真实管线、围栏结构与 200KB 性能回归；全量 **186 tests / 10 suites 全绿**。Release 实测 200KB 单键样式落地 **54.0ms**，连续 11 键最后一键到属性落地 **66.7ms**；最终 dirty 请求仅 **12 / 132171 UTF-16 单元**，不再随文档规模退化成整篇。

> **v1.0 排版与 M5 说明**（2026-08-29）：排版对标 Typora 默认主题（github.css）校准：body 行高 1.6（CJK 折算 multiple 1.35）、段落间距 0.8em 折算 11pt、标题字号 [36/28/24/20/16/16] 且上下 margin 加大、hr 加粗至 2px 且 margin 16px、引用竖线 4px 浅灰。代码块改为带垂直内边距的圆角通宽背景（机制：`Theme.fenceParagraph` 撑出段落间距、绘制层经 `.museBlockRole` 反向延伸背景并画单侧圆角，首行 padding 8px、末行 6px）。
>
> **列表版式重设计**：列表正文列与普通段落正文完全对齐（depth 1 为 0，嵌套按 24pt 步进），圆点/序号/复选框悬挂在左侧留白的固定 24pt lane 里；文本容器左边距 20→28pt 为其留出空间。回显（光标进入列表行）在 TextKit 2 钳制负行起点的约束下改为 Obsidian 式行为：前缀放不下时整行临时右移，收起后精确回位。**（这一段的几何已被 v1.2 推翻：让 depth 1 的正文列等于 0 会把 marker lane 挤到正文左缘之外，列表看起来反而比正文更靠左。见下方 v1.2。）**
>
> **M5 功能**：原生查找替换（`performTextFinderAction:` 响应链接线，查找/替换/下一个/上一个）；图片语法样式（`![` 恒以弱化色可见、目的地随光标显隐）与点击预览（transient NSPopover，支持相对文档目录、`~`、http(s)，未保存文档回退主包资源）；GFM 表格只读呈现（等宽对齐、表头加粗 + 下划线、行分隔线，分隔行整行作为块级 marker 随光标显隐）。缺陷 13 收口：`pendingPair` 的整篇字符串快照失效改为编辑计数器（didChangeText 汇合点），消除每次按键的 O(n) 比较。
>
> 新增图片/表格/围栏角色/正文对齐等回归；全量 **200 tests / 10 suites 全绿**。M4/M5/M6 剩余 gate：真实中文输入法矩阵、真实窗口 checkbox 复核、VoiceOver 朗读人工验收。

> **v1.1 表格与图片修复说明**（2026-08-29）：v1.0 声称的「图片行内呈现」与「表格只读呈现」在真机上都不成立，本轮定位并修掉了根因。
>
> **构建先修**：`Rendering/ImageResolver.swift` 的 `static let cache = NSCache<…>` 在 Swift 6 严格并发下不合法（`NSCache` 未声明 `Sendable`），整个 MuseKit 编译不过——所以 v1.0 记录的「203 tests 全绿」不可能是这份工作树跑出来的。改为 `@unchecked Sendable` 的持有者包一层，把「NSCache 本身线程安全」这件事讲明，而不是用 `nonisolated(unsafe)` 关掉检查。
>
> **图片**：M5 用 `.attachment` 实现行内图片，而它只在 U+FFFC 上成立——`NSTextStorage` 的属性修复会把它从任何其他字符上抹掉（实测见 §4.7），所以一个像素都画不出来。同时 `imageBaseURL` 从未从文档层接到属性层，相对路径一律解析失败。现在：独占一行的图片用 `minimumLineHeight` 预留行高、由 `MuseLayoutFragment` 绘制；`MuseDocument.fileURL` 的 didSet 把文档目录送到 `RenderCoordinator.imageBaseURL`；加载不到的图画带目的地文字的虚线占位框。示例文档原先指向不存在的 `m2-nested-list.png`，改为随包的 `sample-image.png`。
>
> **表格**：旧实现只是「等宽字体 + 通宽底色」，而等宽字体并不能让中文/emoji/ASCII 混排的列对齐（实测 `中` 不是 ASCII 的两倍宽），所以看起来就是没渲染。现在列宽由属性层实测量出，以 `.kern` 落在结构区首字符上（kern 的半分裂语义见 §4.8），绘制层按 `.museTableColumns` 画单元格边框、表头底色与隔行底色；光标进入表格回显源码且不画格线。
>
> **顺带修掉的两处一致性问题**：显隐的全量路径与光标路径各自实现了一遍条目应用，块图片因此从不走光标路径（进出光标不还原）——现在合并为 `RenderEngine.apply(_:imageBaseURL:into:)` 单一入口；`ImagePreviewController` 复制了一份 `resolvedURL`，改为复用 `ImageResolver`。
>
> **性能**：性能语料补入表格与块图片（每 ~150 字节一张表，比任何真实文档都密集）。Release 实测 200KB 属性应用 245ms、1MB 全管线 2149ms、单次真实按键的脏行增量应用稳态 1.3ms；期间修掉两处按文档规模计费的路径（`storage.string` 与整篇折叠区间扫描按 token 重复取、`multilineBlockRanges` 在收敛循环内重复分配）。
>
> 全量 **222 tests / 12 suites 全绿**（Debug + Release），新增 `TableRenderingTests`（列对齐用 Core Text 量渲染后的字形位置，而不是断言 kern 数值）与块图片/占位框/附件剥离的回归守卫。真机窗口已复查：表格网格、列对齐、光标进出表格的回显与收起、本地图行内呈现、缺图占位框。

> **v1.2 列表缩进修复说明**（2026-08-29）：对照 Typora 实机截图，Muse 的列表层级完全不对——**列表没有缩进**，marker 还悬挂到正文左缘之外，看起来比正文更靠左。三条根因：
>
> 1. **缩进模型错了。** v1.0 让 depth 1 的正文列等于 0（与普通段落同列），marker lane 只能挤进文本容器的左页边距里（28pt 边距 − 24pt lane = marker 落在离窗口左缘 4pt 处）。Typora / 浏览器的模型是相反的：`ul, ol { padding-left: 30px }`，**整块列表比正文靠右一步，marker 落在这一步撑出的 padding 里**（`list-style-position: outside`）。现在 `Theme.listIndentStep = 28`，深度 d 的正文列在 `d * 28`，marker lane 落在上一层与本层正文列之间。顺带修掉一个位移 bug：depth 1 正文列在 0 时，回显 `- ` 需要 18pt 却没有余量，TextKit 2 钳掉负行起点后整行右移 18pt——每次点进/点出顶层列表都跳一下。有了一步缩进的余量后位移为零（`- [ ] ` 这类 6 字符前缀仍超出一步，继续走 Obsidian 式临时右移）。
> 2. **marker 左对齐在 lane 起点上，离正文太远。** lane 宽 24pt 是按最宽的 `100.` 定的，窄的 `•` 左对齐进去就离正文空出 17pt（Typora 是 7.6pt），视觉上 marker 像是属于上一层。改成**墨迹右缘贴正文列**（`ListMarkerGeometry.originX`），lane 退化为「宽到什么程度要缩字号」的预算，不再决定落点。实测 depth 1 的圆点因此落在正文左缘右侧 16pt、与正文间隔 7pt，和 Typora 的 15.5pt / 7.6pt 基本一致。代价是 `1.` 与 `•` 不再共用同一个起笔位置（宽的向左伸得更远），这正是浏览器/Typora 的行为——句点对齐比起笔对齐更重要。
> 3. **源码缩进会漏进视觉列。** 旧几何 `bodyColumn = contentIndent + sourceIndentWidth` 把行首空白的宽度算进正文列，于是同一层的条目写 2 空格还是 4 空格会落在不同的列上，缩进不再由语义深度决定；实机截图里二级条目的 marker 与正文之间因此空出 24pt。现在行首空白仍然不折叠（空白没有墨迹，不需要动可见性层），但**从行起点里扣掉**：`firstLineHeadIndent = contentIndent − 可见前缀宽度`、`headIndent = contentIndent`，正文列于是只由 AST 深度决定，一个字符都没改。
>
> 踩到的一个坑：把源码缩进从行起点里扣掉之后，`layoutFragmentFrame.minX` 不再等于正文列（它变成行起点），而绘制层一直把它当正文列锚点用——嵌套 marker 会因此左偏一段空白的宽度。改为向第一行 line fragment 问「第 0 个字符与 marker 之后第一个字符分别落在哪」，差值就是可见前缀的真实推进量，隐藏态与任何缩进写法下都精确。同时发现无序 marker 画的是**矢量图形而不是字形**（字体回退会把 U+25E6 画成实心点），所以它的墨迹盒不能问字体——抽出 `ListMarkerGeometry.unorderedInkBox`，绘制与落点从同一个函数取值。
>
> 全量 **226 tests / 12 suites 全绿**（Debug + Release）。三条几何都做了变异验证：退回 `(level-1)` 步进 → 5 条测试失败；marker 改回左对齐 lane → 2 条失败；去掉源码缩进归一化 → 3 条失败（含量真实绘制像素的 `nestedListMarkersAlignWithIndent`）。新增 `listContentColumnIgnoresSourceIndentWidth`（2 空格与 4 空格的二级条目同列）与 `caretEnteringCommonListItemDoesNotShiftContent`（点进列表不横向跳动）。

---

> **v1.3 引用块连续性与任务复选框**（2026-08-29）
>
> **引用块在第一行就断了。** `appendBlockQuote` 只在 BlockQuote 的**首行**产出一个 token，而 `.museBlock` 由绘制层按 fragment 读取（TextKit 2 里一个段落 = 一行 = 一个 fragment），于是第二行三样东西同时缺失：竖条、底色、以及没人折叠它的 `> `。改成**逐行产出 token**；行号来源统一到 `lineSpan(of:)`，token 的行与 `quoteLines` 集合从同一处取，不可能漂移。顺带修掉嵌套引用的一个既有缺陷：旧代码里每层 BlockQuote 的 marker 都从 `syntaxStart(on:)` 起算，`> > x` 的内外两层指向同一个 `>`，第二个没人管；现在每层只吃自己的 `>` 和紧随的至多一个空格（`quoteMarkerRange`）。懒续行（省掉 `>` 的段落续行）返回空 marker 区间——没有字符要折叠，只拿块视觉。
>
> 仍未做（不假称已修）：嵌套引用**只画一条竖条、不额外缩进**（`quoteParagraph()` 的 18pt 与深度无关，`case .blockquote:` 丢掉了 depth）。
>
> **任务复选框对标 Typora，四项改动。** ① 任务标记**不再随光标回显源码**——它是可点击的控件，回显会让控件在编辑时消失、也让「点一下切换」失去落点（源码模式照旧逐字显示）。副作用是 `- [ ] ` 这个 6 字符前缀的临时右移随之消失，v1.2 里「仍会右移，这是刻意行为」那句话作废。② 复选框从 `☐`/`☑` **字形**改为自绘圆角方框（字体回退下又细又方，圆角/勾形/填充都不可控）。③ 复选框上换成小手光标，范围直接取 `taskCheckboxHitTarget()`——**变小手的范围恒等于点得动的范围**。④ 完成项**不改文字颜色**。
>
> 几何与配色全部由 Typora 实机截图（2x）实测，不是拍的：方框 24px → **12pt**；圆角按「顶行平直段」量得 5 device px → **2.5pt**（比例 5/24）；描边 3px → **1.5pt**，颜色 `#808080` 平灰；勾选填充 `#3478F6`；方框右缘到文字 18px → **9pt**（比圆点的 7pt 宽，两者在 CSS 里本就是不同的盒，所以 `ListMarkerGeometry.gap(for:)` 按 glyph 分流）。
>
> 三条被实测推翻的做法，记下来免得再走一遍：
>
> - **完成项压暗**是我自己加的，Typora 没有。实测截图里勾选行与未勾选行的文字色完全相同（都是 (82,129,191)）。已撤掉，并留下 `completedTaskItemKeepsBodyTextColorAndHasNoStrikethrough` 防止被顺手加回来。
> - **「画系统复选框」听起来更对，实际不对。** Typora 的 github.css 关于复选框只有一条 `margin-left: -1.3em`，看着像是把控件交给了系统；但 WebKit 画 `input[type=checkbox]` 用的是它自己那套仿平台绘制，并不实例化 `NSButton`。macOS 26 把 `NSButton` 的未勾选态改成了**实心浅灰圆角块**，WebKit 没跟——预渲 `NSButton(checkboxWithTitle:)` 成位图的方案因此比自绘更远离 Typora。
> - **勾选色不能跟随 `controlAccentColor`。** 这台机器强调色是默认（`AppleAccentColor` 未设置），`controlAccentColor` 实测解析为 `#007AFF`，而 Typora 画出来是 `#3478F6`——差着一截，跟随系统就对不上「照 Typora 来」。
>
> 全量 **236 tests / 12 suites 全绿**（Debug + Release）。引用的三条几何都做了变异验证：退回「每块只在首行落 token」→ 4 条失败（含量真实绘制像素的 `everyLineOfMultiLineQuoteDrawsItsBar`，quote fragment 只有 1 个而不是 3 个）；去掉嵌套的深度跳过 → 嵌套测试失败 2 处。复选框两态的差异由 `checkedAndUncheckedCheckboxesDrawDifferently` 量真实绘制的**均色**守卫（刻意不取单点：方框正中会落在白勾上，单点阈值得贴着某个系统版本调）。示例文档的引用改成两行，常驻离屏快照因此也覆盖了多行引用。

---

## 00 本轮视觉复查（2026-08-27）

本轮对照截图复查发现并修复了四项列表视觉缺陷：

1. 软换行列表项的一个 paragraph fragment 覆盖多条 `NSTextLineFragment`。旧实现按整个 paragraph fragment 的高度居中 marker，导致 marker 落在段落中部；现改为锚定首个 `textLineFragments.first`。
2. 二级无序 marker 虽然由 AST depth 选择 `◦`，字体 fallback 仍可能把 U+25E6 画成实心点。现在由 `.museListDepth` 驱动 glyph 判定，并在 fragment 绘制层用矢量实心圆、空心圆和方块，确保二级中心留空；绘制层不从源码缩进重新推导 depth。
3. 首行行框包含 glyph 上下方的 leading；把较小字号 marker 居中到 `typographicBounds` 会使圆点和序号整体高于正文。现在读取首个 line fragment 的 `glyphOrigin.y`：有序序号与 checkbox 按 marker font ascender 对齐正文 baseline，无序矢量符号对齐正文 font 的 x-height 视觉中心，不使用固定像素补偿。
4. 有序 marker 旧按自身宽度从正文列向左回推，等同于右对齐；数字 `1` 与 `2` 的可见左边界因字形 side bearing 不同而出现细微错位，也无法与无序 marker 共用稳定左边界。现在 marker 使用段落 `headIndent - firstLineHeadIndent` 推导出的固定槽位，文本 marker 以 Core Text 的实际 glyph path bounds 补偿可见墨迹左边界；多位序号按实际 glyph advance 二分求取槽内最大字号，保留正文列并避免侵入正文。

任务 checkbox 的 checked marker 使用系统 accent 色，unchecked marker 使用 `secondaryLabelColor`，两者都按浅色/深色外观解析。本轮只完成颜色与绘制，不实现点击切换；checkbox 点击将留到 M4，并通过标准文本编辑把 `[ ]`/`[x]` 替换为一次可撤销的源码操作。

本轮新增 6 项真实 TextKit 2/位图回归测试；该轮 Debug 全量证据为 **109 tests / 7 suites**，其中 `RendererTests` 为 **33 项**。这组证据验证了首行锚定、无序 marker 的 x-height 对齐、有序 marker 的 baseline 与固定槽位、`1.`/`2.` 的可见墨迹左边界、`98.`/`99.`/`100.` 不侵入正文、一级实心与二级空心的实际 fragment 像素，以及任务 checkbox 的外观颜色。当前全量结果见 v0.5 阶段审计说明。

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
| B · 原生壳 + `WKWebView` + CodeMirror 6 / Milkdown | 开发快，但输入、字体与系统服务隔着 WebKit | 数周可形成可用原型 | ⚠️ 已不再需要（M0 技术路线 go 判断已成立） |
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
3. **拿不到排版层。** 没有 `NSTextView`、没有 `NSTextLayoutFragment`、没有绘制钩子。§4.9 列出的块级视觉（引用竖线、通宽背景、列表符号、分隔线横线）全部无法实现。

附带发现（可能对 Phase 2 有用）：`AttributedString.MarkdownParsingOptions` 有 `appliesSourcePositionAttributes`，配合 `AttributedString.MarkdownSourcePosition` 能让 Foundation 的 Markdown 解析器输出源码位置。但它仍然只解析不导出，且 `interpretedSyntax` 会吃掉标记字符，不适用于「源码 1:1」的即时渲染。

**结论**：v0.2 排除 SwiftUI `TextEditor` 的判断正确，v0.3 给出了具体依据，避免以后重复评估。

**STTextView（krzyzanowskim）—— 作为参考，不作为依赖**

TextKit 2 的 `NSTextView`/`UITextView` 替代组件，1.5k star，维护活跃（最近推送 2026-08-18）。它的架构与 Muse 在 M2 收口后落地的方案一致：`STTextLayoutFragment` + `STTextView+NSTextLayoutManagerDelegate` + `STTextLayoutFragmentView`——这是对 §4.9 技术选择的独立印证。

两个原因不引入为依赖：

- **授权**：GPL v3 或付费商业授权。闭源产品需购买商业许可。
- **定位**：它替换的是整个 text view，而 Muse 需要的是 `NSTextView` 的原生编辑语义（IME、无障碍、查找、拼写），只在绘制层做扩展。

**但它的价值很高**：作者维护了一份公开的 TextKit 2 缺陷清单（README「TextKit 2 Bug Reports List」），且明确说明该项目存在的原因就是「NSTextView + TextKit 2 并不完全可用，被具体 bug 阻塞后才另起项目」。与 Muse 直接相关的条目见 §4.9。

**D · CodeEditTextView / CodeEditSourceEditor（CodeEditApp）—— 排除**

CodeEditTextView 是**完全自研的排版引擎**，不使用 TextKit（源码中检索不到 `NSTextLayoutManager`）：自建 `TextLayoutManager`、`TextLineStorage`、`TextLine`、`TextSelectionManager`、`MarkedTextManager`。MIT 授权。CodeEditSourceEditor 在其上叠加 tree-sitter 语法高亮。

它的 README 明确划出了自身边界：如果需要「右到左文本、自定义布局元素、或与系统 text view 的功能对等」，应当用 STTextView 或 `NSTextView`。这三项恰好都是 Muse 的需求，所以这条路线不适用——它是「为代码文档换取极快首屏布局」的取舍，而 Muse 要的是富文本布局与系统级编辑语义。

**这仍是一个值得记住的数据点**：一个严肃的开源编辑器项目评估 TextKit 后选择自研，说明 TextKit 2 的成熟度确实有限（与 STTextView 的缺陷清单互相印证）。若 Muse 后期在 TextKit 2 上遇到不可绕过的阻塞，D 是唯一的兜底，但代价是重建 IME 与无障碍。

**自定义 fragment 做 Markdown 渲染已有先例**

多个开源项目采用同一模式，文件名甚至一致：`nodes-app/swift-markdown-engine` 的 `MarkdownTextLayoutFragment.swift`、`no-problem-dev/swift-markdown-view` 的 `MarkdownLayoutFragment.swift`、`bharathvbcr/MarkDev` 的 `MarkdownLayoutFragment.swift`（注释写明「Custom drawing behind code blocks, callouts, quotes, and rules」）。§4.9 的一条实现风险就来自阅读 MarkDev 的源码注释。

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
│  ├─ TypingBehaviors.swift       # M4 列表/标题/自动配对决策
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

自动化与局部真机检查已验证近零宽方案在中文、emoji、组合字符、跨行选择、自动换行、鼠标点击、方向键下的基础行为；M0-3 的完整人工观感、IME 与 VoiceOver gate 仍待回填。降级路径（marker 改弱化色 + 小字号）保留但未启用。

> v0.2 把「自定义 `NSTextLayoutFragment`」列为本节的第三级降级选项。这是分类错误：marker 隐藏（属性层）与块级视觉（绘制层）是两件正交的事，fragment 属于后者且不可绕过。见 §4.9。

### 4.3 块级编辑行为

在 `EditorTextView` / `TypingBehaviors` 中通过标准文本替换接口实现，确保每次操作进入文档 undo manager：

- 列表项 Enter 续项、空项 Enter 退出列表；
- 标题内容起点 Enter 在标题上方插入空段落（标题本体保留，光标留在新空行；引用内的标题会带上 `>` 前缀），空标题则退出标题；
- `**`、`*`、反引号的保守自动配对；
- 行首 `- `、`1. `、`- [ ]` 的块识别；
- 任务 checkbox 点击复用 fragment 的实际绘制几何命中，通过标准文本编辑将源码 `[ ]`/`[x]` 替换，并作为一次 undo 操作；
- undo/redo 后触发新的 revision 和派生渲染。

自动配对必须尊重选区、转义字符、已有闭合符号和 marked text；不要直接在 `keyDown` 中吞掉所有按键，优先使用 `NSResponder` 的命令入口（`insertNewline(_:)` 等覆写）与标准替换入口。

单键开配对的判定：**右侧字符存在且非空白，且左侧不是词字符**（词字符按完整字符簇判定，`rangeOfComposedCharacterSequence`，否则星际平面的字母数字会被误判成非词字符）。已知残留：光标停在已有词前面（`|word`）或句中插入位置（`a |b`）时仍会开配对，产生一个需手删的分隔符——这是刻意接受的折中，因为收紧到「右侧也必须是标点」会让单键配对几乎无法触发。若这类残留在真实使用中成为困扰，就整体去掉单键配对、只保留选区包裹。

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
- 自动配对、列表续行等复合操作显式组成单个 undo group（`breakUndoCoalescing` + `begin/endUndoGrouping`，前后都要切断 AppKit 的 typing coalescing）；
- 复选框点击的门禁走 `shouldChangeText(in:replacementString:)`（官方入口，同时覆盖 `isEditable` 与 delegate 否决），修饰键只排除 `[.command, .option, .control, .shift]`——不能用 `flags.isEmpty`，`deviceIndependentFlagsMask` 含 Caps Lock 等位；
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

M1-2 已恢复 Release 测量链路；历史 Release 全量测试为 103 项 / 7 套件全绿。作为历史对比，v0.2 的手写字节扫描器在 200KB 上是 8.0 ms，但当前全量 AST 仍落在后台与 150ms 样式落地目标内，因此不需要维护第二套 CommonMark 实现。截至 2026-08-27 的 Debug 回归（含该轮 6 项渲染测试）为 109 项 / 7 套件全绿；2026-08-28 当前证据为 Debug/Release 115 项 / 8 套件全绿。

因此顺序是：**先用全量 AST 解析，把架构简化下来**；只有当样式落地延迟实测不达标时，才引入块级脏区重解析——即定位变化所在的顶层块，只对该块调用 `Document(parsing:)`，而不是维护第二套 CommonMark 实现。swift-markdown 与 cmark-gfm 都不提供增量解析 API。

### 4.7 图片

**独占一行的图片直接呈现在正文里**（原计划的 Phase 2 已落地）；夹在正文中间的图片保持源码呈现。

**`NSTextAttachment` 这条路是死的，不是「暂时不做」。** `.attachment` 只在 `NSAttachmentCharacter`（U+FFFC）上成立：`NSTextStorage` 的属性修复（`endEditing` → `fixAttributesInRange:`，AppKit 头文件里写明「NSTextAttachmentAttributeName is assigned to NSAttachmentCharacter」）会把它从任何其他字符上**抹掉**。实测：

```text
addAttribute(.attachment, …) 在 beginEditing 内   → 属性在
endEditing 之后                                  → 属性没了
直接 addAttribute（不在编辑会话内）              → 立刻就没了
加在 U+FFFC 上（对照）                           → 属性在，行高从 16 涨到 33
```

而「只写属性、不改字符」不允许插入 U+FFFC。M5 曾按附件实现行内图片，这正是它一个像素都画不出来的原因（回归守卫见 `RendererTests.attachmentAttributeIsStrippedFromOrdinaryCharacter`）。

**实际路线**（§4.9 的自定义 fragment 是既有设施）：

1. **判定**：`![标签](目的地)` 两侧只有空白 → 块图片。判定放在 AST 层（`MarkdownSemantics.blockImageLines`），渲染层与显隐层读同一个答案。
2. **预留空间**：`paragraphStyle.minimumLineHeight = 图片高度`。这是不改字符能拿到垂直空间的唯一公开手段——TextKit 2 的 rendering attributes（`NSTextLayoutManager.addRenderingAttribute`）只影响绘制、**不参与排版**（实测：rendering 的 `minimumLineHeight: 90` 之后 fragment 仍是 32pt）。
3. **绘制**：`MuseLayoutFragment` 读整行上的 `.museImagePath` / `.museImageSize`，把图画进保留区；`renderingSurfaceBounds` 要 union 到图片尺寸，否则被裁成一条线。
4. **显隐**：块角色与撑高的行高由**显隐层独家**决定（`applyInlineImageVisibility`）。样式层只写「输入」（目的地、路径、尺寸）——两处都写会互相兜底，任一处坏掉测试都测不出来。光标进入该行 → 撤掉块角色、行高回到普通段落、露出源码，这是改图片路径的入口。
5. **解析基准**：相对路径按文档目录解析，所以 `imageBaseURL` 必须一路传到属性层（`MuseDocument.fileURL` 的 didSet → `RenderCoordinator.imageBaseURL` → `RenderEngine`）。图片尺寸决定行高、行高是属性，不能留给绘制时临时解析。

**已知边界**：只同步加载本地图。远程地址（http/https）画带目的地文字的虚线占位框，点击弹 popover 异步加载真图；行内远程图的异步加载 + `invalidateLayout` 重排留作后续（TextKit 2 有公开 API：`NSTextLayoutManager.invalidateLayout(for:)` / `NSTextLayoutFragment.invalidateLayout()`）。夹在正文中间的图片不撑高该段，整段源码弱化成 marker 色保留——折叠一半只会留下 `![标签` 这种看起来像打错字的残句。

### 4.8 表格：列对齐只能靠 kern

GFM 表格要看起来像表格，列必须对齐。**源码里的列宽是按字符个数对齐的，而字符个数不等于宽度**——实测 `.monospacedSystemFont(13)` 下 `M` 8.04pt、`中` 12.90pt、`🎉` 19.00pt，`中` 并不是 ASCII 的两倍，等宽字体也救不了。这就是「表格没渲染」的根因。

可选项逐个排掉：

| 方案 | 结论 |
|---|---|
| `NSTextTable` / `NSTextTableBlock` / `paragraphStyle.textBlocks` | **TextKit 1 专有**。全部布局/绘制入口都按 `NSLayoutManager` 声明，26.5 SDK 没有为 TextKit 2 补任何东西。实测同一份带 `textBlocks` 的属性串：TK1 排出真表格（`usedRect 601×92`，单元格在 x=5/205/405），TK2 把 9 个单元格竖着摊成 9 个 fragment。姊妹设施 `NSTextList` 也有公开回归（FB14700414）。 |
| `paragraphStyle.tabStops` | TextKit 2 确实生效（实测停靠在 120/280 分毫不差），但需要正文里有真的 `\t`。GFM 表格里没有，而插字符是铁律禁止的。 |
| TextKit 1 的字形替换（`NSGlyphProperty.elastic`） | TextKit 2 没有对等能力：`NSTextLayoutManager.h` / `NSTextLayoutFragment.h` 里 `glyph` 出现 0 次，delegate 只有 3 个方法。 |
| 只靠自定义 fragment 画 | 光标与选区几何来自 `NSTextLineFragment.typographicBounds`，绘制时挪字形会让命中测试与光标全部错位。fragment 只能画装饰。 |
| **`.kern`** | **采用**。它改的是真实推进量，所以光标、选区、命中测试自动一致。 |

**kern 的半分裂（文档没写，实测得出）**：对索引 i 的字符加 kern K，**i 与 i+1 各分到 K/2**：

```text
"X|abc|Y"  基线      : X=0  |=10.55  a=14.38  b=22.89  c=32.41
在 index 1 加 kern 100: X=0  |=10.55  a=64.38  b=122.89 c=132.41
                                       ↑ +50      ↑ +100
```

所以想把一段文字**整体**平移 K，承载字符必须落在它前面**至少两个字符**处；中间那个字符会吃掉半个 K，它自己的落点必须无所谓。表格刚好满足：`| 文字 |` 里「上一格尾部空白 + `|` + 本格头部空白」都是要折叠的结构字符。承载字符取这段结构区的**首字符**，墨迹稳稳落在 i+2 之后。

落地分工：

- **AST 层**（`TableStructure`）：单元格墨迹（去掉两侧空白）、结构区、列对齐，全部由 `Table.Cell.range` 还原——cmark 的 column 是**字节**列，与本项目同源。
- **属性层**（`TableLayout`）：量每格墨迹宽度（每格只量一次）→ 列宽取各行上界 → 按对齐算目标 x → kern 写到结构区首字符；列边界随行写进 `.museTableColumns`。
- **绘制层**：读列边界画单元格边框、表头底色、隔行底色。列宽是**跨行**的最大值，fragment 只看得见自己那一行，没有能力自己算。
- **回显态不画格线**：光标进入表格时源码里的 `|` 全露出来，格线还停在渲染态的列位置上，两套竖线叠在一起比不画更乱。

**兜底**：完全不留空格的写法（`|a|b|`）结构区只有 1 个字符，放不下承载字符 → `isAlignable == false` → 退回「弱化底色 + 表头加粗、不画格线」，而不是硬画一个和文字错位的表格。

**另外两处必须知道的量**：单元格上下内边距要**分开撑**——TextKit 把行高增量全部加在基线**之上**（实测 `minimumLineHeight = 30` 时基线在 27，字形贴着底边、降部还越界），所以上内边距用 `minimumLineHeight`、下内边距用 `paragraphSpacing`。以及 kern **参与断行**（实测 kern 80 的行在 120pt 容器里被折成两行），表格行必须 `lineBreakMode = .byClipping`。

### 4.9 块级视觉：绘制层

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
6. **列表 marker**：软换行时以 `textLineFragments.first` 的真实 line geometry 锚定 marker，而不是用整个 paragraph fragment 的高度居中；无序 marker 的 depth 直接读取 AST 写入的 `.museListDepth`，并用矢量实心圆/空心圆/方块保证二级视觉留空（矢量形状的墨迹盒由 `ListMarkerGeometry.unorderedInkBox` 统一给出，绘制与落点同源）。横向落点是**墨迹右缘贴正文列**（`list-style-position: outside` 模型，见 v1.2）：`markerLaneWidth` 只作为「宽到什么程度要缩字号」的预算，多位序号在预算内缩放且不移动正文列。正文列不能用 `layoutFragmentFrame.minX`（行首源码缩进已从行起点里扣掉，那是行起点不是正文列），而是向第一行问 marker 之后第一个字符的落点。
7. **任务 checkbox**：自绘圆角方框，几何与配色由 Typora 实机截图实测（见 v1.3）——不是 `☐`/`☑` 字形，也不是系统控件。checked 用实测的 `#3478F6` + 白勾，unchecked 用 `#808080` 描边 + 白底，两者都按浅色/深色外观解析。落点与点击命中共用 `ListMarkerGeometry.taskCheckboxBox`。**任务标记不随光标回显源码**：复选框是可点击的控件，回显会让它在编辑时消失、也让「点一下切换」失去落点（源码模式仍逐字显示）。

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

- 表格渲染（对齐网格，只读）。解析层免费——AST 默认就产出带 source position 的 `Table`/`Row`/`Cell`；列宽由属性层实测量出、以 `.kern` 落到结构字符上，格线由绘制层画（§4.8）。表格的**可视化编辑**（列宽拖拽、增删行列）仍留 Phase 2。

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
| M0 技术验证 | 3～5 天 | TextKit 2 明确启用；中英文/emoji 下区间正确；marker 隐藏、选区、换行、IME、undo、VoiceOver 可接受；**块级视觉在真机窗口中可见**；20KB/200KB 基准有数据 | ⚠️ 有条件通过：实现与自动化完成，M0-3 人工 gate 待回填 |
| M1 骨架 | 1 周 | Xcode 工程；`NSDocument → EditorBuffer → NSTextStorage` 单一所有权；open/save/autosave；SwiftUI 外壳 | ✅ 通过（当前 Debug/Release 回归均通过） |
| M2 解析与渲染 | 1.5～2 周 | `SourceIndex`、AST 语义层、后台 revision 管线；标题、强调、代码、链接；**块级视觉绘制地基（自定义 fragment）**；单元测试覆盖 Unicode 与未闭合语法 | ✅ 通过（M2-1～M2-9 已收口；当前 Release 性能达标） |
| M3 光标交互 | 1.5～2 周 | marker 回显、方向键、鼠标命中、跨行选区、源码模式；无 TextKit 1 fallback | ✅ 通过（系统原生输入/命中；源码模式不改字符） |
| M4 块行为 | 1 周 | 列表续行/退出、标题行为、任务 checkbox 点击将源码 `[ ]`/`[x]` 标准替换、自动配对；复合操作一次撤销 | 🚧 自动化完成（含缺陷 13 收口）；真实 IME、checkbox 与 VoiceOver 人工 gate 待验收 |
| M5 收尾功能 | 1 周 | 图片预览、查找替换、源码模式打磨、（候选）表格渲染 | 🚧 查找替换、排版对标 Typora、表格对齐网格、块图片行内呈现均已真机复查（v1.1）；剩余待验收项为源码模式打磨 |
| M6 稳定与发布准备 | 1～2 周 | IME 矩阵、autosave/reopen、崩溃恢复、性能、VoiceOver、主题和回归测试 | 🚧 可自动化项完成：autosave 落盘、reopen 还原、崩溃恢复配置守卫（autosaveInPlace）、主题（亮/暗调色板与块视觉像素）回归、性能达标，离屏视觉快照守卫假绿；剩余 gate 为真实 IME 矩阵与 VoiceOver 人工验收 |

**v0.3 对里程碑的两处调整：**

1. **块级视觉从 M5 前移到 M2/M3。** v0.2 把「代码围栏、引用、分隔线」放在 M5「收尾功能」，但它们依赖 §4.9 的绘制地基。把地基放在最后一个功能里程碑等于把最大的架构风险留到最后；实际也已经发生——这些功能在 M2 期间被提前实现，但因地基缺失全部不可见。M5 相应改为图片预览与打磨。
2. **M0 gate 补入绘制层验收。** v0.2 版 M0 的十项人工验收全部围绕属性层，没有一项检查块级视觉能否画出来，导致假绿测试存活。

M0 仍是 go/no-go gate。工程开发可以在已验证的技术路线上继续，但在宣称“M0–M2 全部正式通过”或进入发布准备前，必须完成并回填 M0-3 人工验收。

## 07 风险

| 风险 | 等级 | 对策 |
|---|---|---|
| UTF-8 `SourceRange` 与 UTF-16 `NSRange` 错位 | P0 | 独立 `SourceIndex`；中文、emoji、组合字符和多行 golden tests |
| 视图级绘制在 layer-backed TextKit 2 上无效 | P0 | 块级视觉一律走自定义 `NSTextLayoutFragment`；测试断言必须经由 `layoutManager` 真实生产的 fragment（§4.9） |
| 双层解析实现产生语义分叉 | P0 | AST 是唯一语义与定位来源；扫描器职责严格限于未闭合语法；对 AST 做差异测试（§4.1） |
| 零宽 marker 破坏换行、命中或辅助功能 | P0 | 自动化与局部真机证据已覆盖基础行为；M0-3 完整人工 gate 待回填；降级路径（弱化显示）保留 |
| IME 与异步渲染互相干扰 | P0 | 跳过 marked range；后台快照 + revision；中文输入矩阵 |
| 文档模型与 text view 出现双重真相 | P0 | `EditorBuffer.textStorage` 是唯一可变正文；SwiftUI 不回写整篇字符串 |
| 测试绕过真实渲染路径产生假绿 | P1 | 渲染测试必须走 `NSTextLayoutManager` / `NSTextStorage` 真实路径；禁止直接调用绘制函数断言像素 |
| fragment 内解析动态色导致暗色模式失效 | P1 | 不在 fragment 内取 `NSColor.cgColor`（`NSAppearance.current` 为 nil 时静默回落亮色）；改用共享的已解析 `CGColor` 调色板，外观变化时整体替换（§4.9） |
| TextKit 2 自身缺陷（多余 line fragment、私有 API 依赖等） | P1 | 参照 STTextView 公开的缺陷清单预判（§2.1、§4.9）；文末空行与首帧块视觉专项检查 |
| 派生属性污染 undo 栈 | P1 | undo 只记录源码；撤销后重算渲染，不做整篇快照式 undo |
| 样式落地延迟不达标 | P1 | 先测全量 AST（200KB 实测 65ms Debug）；不达标时做块级脏区重解析，不自建 CommonMark |
| TextKit 2 意外降级为 TextKit 1 | P1 | 显式创建；禁止访问 `layoutManager`；开发期监听 fallback 通知并断言 |
| 行内图片破坏源码 1:1 | P1 | 已解决：`.attachment` 只在 U+FFFC 上成立（实测被属性修复抹掉），改走 §4.9 的 fragment 绘制 + `minimumLineHeight` 预留行高，一个字符都不插入（§4.7） |
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
- 任务 checkbox checked 使用系统 accent 色、unchecked 使用外观感知的 secondary label 色；点击图形可切换 `[ ]`/`[x]`，并作为一次 undo；
- 光标进入块内时源码 marker 回显、图形符号让位；
- **暗色模式下逐项检查块视觉配色**（动态色在 fragment 内解析会静默回落亮色，见 §4.9）；
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
- 快速连续输入时旧 revision 不覆盖新内容，pending dirty range 在插入/删除后保持当前 UTF-16 坐标；
- 200KB 连续输入的最终装饰范围保持局部，输入 burst 只启动一次最新快照解析；
- 打开、保存、Save As、autosave、reopen、外部文件变化与崩溃恢复；
- 多窗口/多文档之间的 text storage、undo manager 和主题状态完全隔离。

---

**下一步：**完成 M4/M5/M6 共同的人工 gate：用真实中文输入法覆盖候选、上屏、取消与 Enter；在真实窗口复核 checkbox 点击、图片预览弹层、⌘F 查找栏与 undo/redo；用 VoiceOver 逐项确认隐藏 marker 不重复、不遗漏正文；在 App 内切换系统外观复核暗色块视觉（自动化为像素/调色板断言，观感以实机为准）。当前自动化证据为 **203 tests / 11 suites**，其中可访问值回归确认完整 Markdown 源码仍暴露给辅助功能，离屏视觉快照（/tmp/muse-snapshot-light.png）确认真实渲染路径非空白。

连续输入的整篇装饰退化已关闭：pending dirty range 会跨插入/删除重基并随 revision 一起提交，8ms 输入 burst 去抖避免已取消解析继续争抢 CPU。Release 200KB 探针为单键 54.0ms、连续 11 键最后一键 66.7ms，最终 dirty 仅 12 / 132171 UTF-16 单元。后续性能工作转向更大文档的解析增量化与真实键盘节奏 P95，而不是再次放大装饰范围。

## 参考资料

### Apple

- [What's new in TextKit and text views（WWDC22）](https://developer.apple.com/videos/play/wwdc2022/10090/)
- [Meet TextKit 2（WWDC21）](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [TextKit](https://developer.apple.com/documentation/appkit/textkit)
- [NSTextLayoutFragment](https://developer.apple.com/documentation/appkit/nstextlayoutfragment)
- [NSTextLayoutManagerDelegate](https://developer.apple.com/documentation/appkit/nstextlayoutmanagerdelegate)
- [NSTextViewDelegate.textView(_:doCommandBy:)](https://developer.apple.com/documentation/appkit/nstextviewdelegate/textview(_:docommandby:))
- [NSTextAttachment](https://developer.apple.com/documentation/appkit/nstextattachment)
- [SwiftUI TextEditor](https://developer.apple.com/documentation/swiftui/texteditor)（macOS 26 的 `AttributedString` 绑定，见 §2.1）

### 解析

- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [swift-markdown SourceLocation](https://github.com/swiftlang/swift-markdown/blob/main/Sources/Markdown/Infrastructure/SourceLocation.swift)

### 调研过的替代方案与参考实现（§2.1）

- [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) —— 使用 CodeMirror 官方 Markdown 命令完成列表续行，并单独处理代码围栏与 checkbox；其 Web 编辑栈不适合直接引入 Muse，但交互边界可参考。
- [CotEditor](https://github.com/coteditor/CotEditor) —— 原生 AppKit 编辑器；其保守成对输入、选区包裹、已有闭合符跳过及标准 `insertText` 路径直接参考了本轮实现。
- [STTextView](https://github.com/krzyzanowskim/STTextView) —— TextKit 2 的 text view 替代组件（GPLv3 / 商业双授权，不作为依赖）。其 README 的 **TextKit 2 Bug Reports List** 是本方案 §4.9 缺陷清单的来源。
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) / [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) —— 完全自研排版引擎 + tree-sitter（MIT）。§2.1 的 D 路线。
- [MarkDev](https://github.com/bharathvbcr/MarkDev) —— 自定义 fragment 做 Markdown 块级绘制的先例；§4.9 的动态色隐患线索来自其源码注释。
