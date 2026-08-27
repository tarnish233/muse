# M0 技术验证报告

- 日期：2026-08-26（2026-08-27 补充 §8 gate 复盘）
- 范围：v0.2 方案 §06 中 M0 的 go/no-go gate
- 结论：**通过（属性层）+ gate 定义有缺口（绘制层）**
  - 自动化验证全绿；零宽 marker 的视觉、IME、VoiceOver 三项需人工验收，见 §6。
  - 2026-08-27 追加：本次 gate 的十项验收全部围绕**属性层**，没有一项检查**绘制层**（块级视觉能否在真机画出来）。该缺口在 M2 期间导致一个 P0 缺陷长期不可见。详见 §8。技术路线本身的 go 判断不变。

## 1. 交付物

| 交付物 | 位置 | 状态 |
|---|---|---|
| Muse.xcodeproj（Xcode 26 / Swift 6，TextKit 2 显式启用） | `Muse.xcodeproj` | ✅ |
| 最小可编辑 App（含示例文档 + 渲染统计栏） | `Muse/`（App/Document/Editor/Parsing/Rendering） | ✅ |
| SourceIndex（UTF-8 ↔ UTF-16） | `Parsing/SourceIndex.swift` | ✅ 8 项测试 |
| TokenScanner（M0 版 8 种语法 + 块内行内扫描 + 转义） | `Parsing/TokenScanner.swift` | ✅ 23 项测试 |
| 渲染引擎（属性层：样式 + marker 隐藏/回显 + 脏行增量） | `Rendering/RenderEngine.swift` | ✅ 11 项测试 |
| 渲染协调器（后台解析 + revision + 显隐 diff） | `Document/RenderCoordinator.swift` | ✅ 随渲染测试覆盖 |
| 性能基准 | `MuseTests/PerformanceTests.swift` | ✅ 4 项 |
| 文档往返（NSDocument 序列化） | `MuseTests/DocumentTests.swift` | ✅ 4 项 |

总计 **50 项测试全绿**（Swift Testing）。

## 2. 性能基准（Debug 构建，Apple Silicon）

**全管线（打开/首渲路径，整篇应用）**：

| 文档规模 | 扫描+索引 | 整篇属性应用 | 合计 |
|---|---|---|---|
| 20KB（624 tokens） | 0.9 ms | 11.6 ms | ~12.5 ms |
| 200KB（6,136 tokens） | 8.0 ms | 111.0 ms | ~119 ms |
| 1MB（676,760 字） | — | — | 926 ms（全管线） |

**输入热路径（单键脏行增量应用，两轮审查后）**：

| 层级 | 200KB 实测 |
|---|---|
| 引擎层 applyDirty（重置+重排脏行带） | **1.65 ms** |
| 协调器端到端（编辑→快照→后台解析→revision 校验→增量应用→marker 显隐 diff） | ~37 ms（含 ~8ms 后台解析；主线程部分 ≈ 3ms） |

**解读**：解析层（字节扫描 + SourceIndex）完全不是瓶颈（200KB 仅 8ms），且已移出主线程；主线程按"编辑到样式落地"只承担快照拷贝 + 脏行带增量应用 + 显隐 diff。输入主线程预算（<16ms P95）从架构与实测上满足；37ms 的端到端延迟是含后台解析的"样式落地延迟"，不阻塞输入。整篇全量应用（~110ms @ 200KB）只存在于打开/首渲路径。

## 3. 关键验证结论

1. **区间正确性（P0）**：中文、emoji、ZWJ 家族、组合字符、CRLF 下 UTF-8↔UTF-16 双向转换与边界钳制全部通过，含落在多字节字符中间/ surrogate 对中间的下取整行为。
2. **marker 隐藏**：近零宽字体（0.1pt + 透明前景）在属性层工作正常；光标进入内容区时双向分隔符回显、离开后隐藏；块级 marker 按"光标所在行"显隐 —— 规则与 Typora 一致。
3. **"渲染不改字符"**：全流程字符数不变（渲染前后 `storage.string` 相等），undo/IME 兼容的前提成立。
4. **TextKit 2**：手工栈创建（`NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer → NSTextView`），全程无 TextKit 1 API 访问。
5. **渲染与 undo 解耦**：属性修改包在 `disableUndoRegistration` 内（v0.2 4.5：渲染属性不进撤销栈），文本撤销后由编辑回调自动重算渲染 —— 一次撤销 = 文本一步到位，不出现"先撤样式"的中间步。

## 4. 实现取舍（与方案差异记录）

- **SourceIndex 实现为"按 scalar 全量表"**而非"逐行缓存"：查询 O(log n) 且支持任意位置的双向转换，代价是内存（200KB 文档约 1–3MB），可接受；后续若需要再优化为行缓存。
- **编译错误级修复**：CJK 文本上 AppKit 会把系统字体解析为 PingFang 回退字体，测试断言改用字重/字号而非字体实例相等（已在测试中注释说明）。
- 测试目标（MuseTests）直接编译 Document/Parsing/Rendering 源码（非宿主 App）：Swift Testing 在 AppKit 宿主进程里跑完不退出（测试宿主持有进程），改为独立进程执行；App 与测试各持一份源码副本，M1 视情况引入框架化或回归宿主。
- 未做（M0 明确范围外）：swift-markdown 语义 AST（M2）、链接/图片语法（M2/M5）、`***` 的 CommonMark run 分析（M2）。

## 5. 审查修复（2026-08-26，M1 后）

外部审查（P1×2 / P2×4 / P3×1）全部处理：

- **P1 渲染管线出主线程**：后台解析（不可变 Snapshot + revision 递增 + 任务取消 + 过期结果丢弃）+ 主线程仅"脏行带"增量应用（200KB 实测 0.58ms，相对整篇 111ms 约 190 倍改善）；属性写入全程包在 undo 抑制内（v0.2：渲染属性不进撤销栈，撤销后由编辑回调自动重算）。
- **P1 块级内容不扫行内**：标题/列表/任务/引用的内容区间现在参与行内扫描（`- **粗体**` 正确渲染）。
- **P2 marker 显隐 diff 写入**：光标流改为"重算状态 + 仅写翻转 marker"（缓存按 marker 键控，批量 beginEditing/endEditing）。
- **P2 嵌套强调 traits**：`NSFontManager` 归一化后一次性加特征（直接链式 convert 会静默丢特征，descriptor 合成会把 semibold 掉回 regular）；反向嵌套（`*a **b** c*`）受限于 scanner 的运行分析简化，记入 M2。
- **P2 首屏显隐**：textView 挂接后补一次 `refreshMarkerVisibility`。
- **P2 转义闭合符**：`findScalar/findSequence/findRun` 跳过 `\x` 转义对。
- **P3 测试统计**：本节同步为 50 项。

### 5.1 第二轮复审（2026-08-26）：异步增量管线收口

- **P1-1 连续编辑丢失脏区**：取消旧任务时若本轮应用前已有多次编辑，dirty 无法安全合并（文本坐标随编辑漂移）→ 回退整篇应用；单次编辑仍走增量。`rapidEditsCoalesceDirtyRanges` 回归测试。
- **P1-2 光标流用旧 package**：`editsSinceApply > 0` 时禁止显隐更新（后台解析落地时按最新选区重算），避免旧区间写新存储导致越界/错位。`stalePackageGuardSkipsCursorFlow` 回归测试。
- **P1-3 换行/围栏编辑重排范围**：脏行带 = editedRange 行 + 1 邻居行（换行拆分）+ 与脏区相接的**旧/新**围栏整块 + 邻近引用归属变化行。实现为纯计算（对比前后 package 的结构），不读存储属性——TextKit 2 存储的属性读取实测 ~56µs/次，读存储会让热路径退化 10 倍。`dirtyCoversSplitLineAfterNewlineInsert`、两个围栏结构回归测试。
- **P1-4 marker diff 身份**：RevealKey 从绝对 UTF-8 偏移改为（行号, 行内相对偏移）——文档前部插入字符不再让全部 cache miss。`markerDiffStableUnderFrontInsertion` 验证 200KB 文档前部插入后写入数 < 总量 1/10。
- **P2 性能测试走真实协调器路径**：`perfCoordinatorSingleKeystroke200KB` 覆盖"编辑回调→快照→后台解析→revision→应用→reconcile"全程（测得 ~37ms 端到端，其中后台解析 ~8ms）。
- 测试总数升至 **57 项**（6 个套件）。

## 6. 人工验收清单（需要打开 App 逐项确认）

```bash
open build/Build/Products/Debug/Muse.app
```

| # | 项目 | 操作 | 预期 |
|---|---|---|---|
| 1 | 零宽留白 | 观察粗体/斜体/行内代码两侧 | 隐藏的 `**`/`` ` `` 不应产生可见空隙 |
| 2 | 中文 IME | 在正文/粗体内容内用拼音输入 | 候选窗正常、上屏后样式立即生效、无排版跳动 |
| 3 | IME 候选态 | 拼音候选时按 ←/→/Enter/Esc | 不破坏 marker 显隐、不崩溃 |
| 4 | 方向键穿越 | 用 →/← 经过隐藏 marker 的 span | 光标按字符移动，跨过 marker 时行为稳定 |
| 5 | 鼠标点击 | 点击隐藏 marker 附近 | 命中位置准确，marker 按规则回显 |
| 6 | 跨行选择 | 从 span 内拖选到段落外 | 选中高亮正常，选区内 marker 保持可见 |
| 7 | 撤销 | 在粗体内打字后 Cmd+Z | 一次撤销 = 文本 + 样式一起还原（不出现"只有样式变"的中间步） |
| 8 | 换行 | 观察自动软换行与超长行 | 隐藏 marker 不影响换行位置 |
| 9 | VoiceOver | 开启旁白朗读 | 不应朗读 `**` 等隐藏标记（已知风险：M0 用透明色实现，旁白可能读到标记字符；若影响明显，M1 用 `accessibilityTextCustom` 处理） |
| 10 | 亮/暗主题 | 切换系统外观 | 配色正常切换 |

**第 1、2、7、9 项是 gate 的关键项**：若 1 或 2 有明显问题，按 v0.2 §4.2 的降级路径执行（marker 改弱化色 + 小字号，保留可预测宽度），在 M0 结束时固定交互规范，不带病进 M1。

## 7. 下一步

1. 人工验收清单（§6，第 1/2/7/9 项为 gate 关键项）。
2. M1 骨架已完成，见《M1 评价报告》。
3. M2 解析与渲染已完成（有条件通过），见《M2 评价报告》。
4. M3 光标交互：marker 回显手感打磨、方向键与鼠标命中、源码模式切换；之后 M4 块行为（列表续行/退出、标题行为、自动配对）。

## 8. Gate 复盘（2026-08-27 追加）

M0 的判断「技术路线可行、零宽 marker 方案成立」经后续里程碑验证是对的。但**gate 的覆盖面漏了一整层**，这里记录下来避免后续里程碑重犯。

### 8.1 漏了什么

§6 的十项人工验收（零宽留白、IME、方向键、鼠标、选择、撤销、换行、VoiceOver、主题）与 §3 的五项关键结论，全部落在**属性层**——「往 `NSTextStorage` 写字体/颜色/段落样式，字符数不变」。

没有任何一项验证**绘制层**：属性写不出来的东西（引用竖线、通宽背景、列表图形符号、分隔线横线）能否真的画到屏幕上。

M0 当时的范围声明（§4「未做」）列了 swift-markdown、链接/图片、`***` run 分析，但没有把「块级视觉」列为已知空白——因为 v0.2 方案把它归入 M5「收尾功能」，当时并不认为它是技术验证项。

### 8.2 后果

M2 期间实现了列表符号、引用竖线、通宽背景、分隔线横线，代码路径挂在 `NSTextView.draw(_:)` 上。实测这条路径在 layer-backed 的 TextKit 2 `NSTextView` 上**完全无效**——所有块视觉一个像素都画不出来，而同期的单元测试全绿（测试直接调用绘制函数往位图里画，绕过了真实的 TextKit 图层路径）。

缺陷存活了整个 M2，直到人工对照 Typora 截图才发现。详见《M2 评价报告》§3、§4。

### 8.3 根因

M0 的铁律「渲染只写属性、不改字符」被验证得很扎实，但它只是这条铁律的一半。另一半——**「只写属性画不出块视觉，块视觉必须走另一条路」**——既没进 gate，也没进方案的风险表。

一个「技术验证」里程碑的作用是把不确定性提前引爆。属性层的不确定性（区间、IME、undo、零宽）被充分引爆了；绘制层的不确定性完全没有被触碰，于是它推迟到 M2 才引爆，而且是以「测试全绿但产品是空的」这种最坏形式。

### 8.4 已采取的修正

- v0.3 方案 §4.8 新增「块级视觉：绘制层」，把自定义 `NSTextLayoutFragment` 从「Phase 2 可选升级」改为 MVP 地基，并记录实测细节与 TextKit 2 已知缺陷。
- v0.3 方案 §06 的 M0 退出条件补入「块级视觉在真机窗口中可见」。
- v0.3 方案 §07 新增两条风险：「视图级绘制在 layer-backed TextKit 2 上无效」（P0）、「测试绕过真实渲染路径产生假绿」（P1）。
- v0.3 方案 §08 验证清单新增「渲染与绘制」一节。

### 8.5 对后续 gate 的要求

每个里程碑的退出条件必须回答一句话：**「这个里程碑交付的东西，有没有在真机上被眼睛看到过？」** 单元测试可以证明属性写对了，不能证明像素画出来了。凡是涉及视觉产出的里程碑，验收必须包含一次真机截图核对。

---

## 9. 接下来要做什么（M0 收尾）

M0 的代码部分已完成。剩下的是**验收动作**，分两类：可自动化的交给 Codex，必须人眼/人手的由人执行。

### 9.1 全局约束（所有任务通用，不得违反）

1. **渲染只写属性，不改字符。** 任何改动后 `storage.string` 必须与源码逐字节相等。已有 `DocumentTests.renderNeverChangesDocumentSource` 守着，不要绕过它。
2. **禁止访问 TextKit 1 的 `layoutManager`。** 只用 `textLayoutManager`。
3. **渲染测试必须走框架真实产出的对象。** 不允许「自己造 `NSGraphicsContext` + 直接调绘制函数」然后断言像素——这正是 M2 那个假绿缺陷的成因（见《M2 评价报告》§4）。块视觉的断言必须经由 `layoutManager.enumerateTextLayoutFragments` 拿到的 fragment。
4. **属性写入不得进入撤销栈。** 保持包在 `disableUndoRegistration` 内。
5. 每个任务完成后跑全量测试：`xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS,arch=arm64' -derivedDataPath build`。当前基线 **78 项 / 7 套件全绿**，不允许变红。

### 9.2 任务 M0-1：块级视觉的自动化回归（Codex）

**现状**：块视觉修复后只做过一次人工截图确认，没有自动化回归。下次改动很容易再次悄悄失效。

**要做**：在 `MuseTests/RendererTests.swift` 中补一组测试，覆盖每一种块视觉都能经由真实 fragment 落墨。

- 测试名：`blockVisualsRenderForEachBlockKind`
- 语料需同时包含：无序列表、有序列表、任务列表（勾选与未勾选）、引用块、代码围栏、分隔线
- 对每一种 `BlockVisual`，断言存在一个 `MuseLayoutFragment` 其 `blockKind` 匹配，且其绘制落墨像素 > 0
- 参考现有 `blockVisualsComeFromLayoutFragments` 的写法（它已经建立了正确的取 fragment + 分离字形像素的模式）

**验收**：新测试存在且通过；故意把 `EditorTextView.make` 里 `layoutManager.delegate = provider` 这一行注释掉后，该测试必须**失败**（证明它真的在守护委托挂接，而不是又一个假绿）。

### 9.3 任务 M0-2：暗色模式块视觉自动化断言（Codex）

**现状**：`MuseLayoutFragment` 在绘制时对动态 `NSColor` 取 `.cgColor`，实测该调用按 `NSAppearance.current` 解析，且 current 为 nil 时**静默回落亮色**：

```text
NSAppearance.current = .aqua     → [0.96, 0.97, 0.98, 1.0]
NSAppearance.current = .darkAqua → [0.15, 0.17, 0.19, 1.0]
NSAppearance.current = nil       → [0.96, 0.97, 0.98, 1.0]   ← 回落
```

**要做**：先写一个**会失败**的测试把问题固定下来（红），再由 M2-6 修复转绿。

- 测试名：`blockVisualsFollowAppearance`
- 做法：在 `.aqua` 与 `.darkAqua` 两种 `NSAppearance.current` 下分别经真实 fragment 绘制引用块到位图，采样引用背景区域的像素
- 断言：两次采样的颜色**不同**
- 若当前实现下该测试失败，用 `withKnownIssue` 标注并注明「待 M2-6 修复」，不要用 `#expect` 反向断言把 bug 写成规格

**验收**：测试存在；M2-6 完成后移除 `withKnownIssue` 且通过。

### 9.4 任务 M0-3：人工验收清单（**需要人执行，Codex 无法替代**）

§6 的十项从未有过执行记录。以下逐项确认后，把结果（通过/问题描述）回填到 §6 表格的新增一列「实测结果」。

```bash
open build/Build/Products/Debug/Muse.app
```

Codex 可以做的准备工作：把 §6 表格加一列「实测结果」并留空，方便回填。

**必须人工的项**（原 §6 第 1–10 项）中，gate 关键项是 **1（零宽留白）、2（中文 IME）、7（撤销）、9（VoiceOver）**。

**新增三项**（v0.3 §08「渲染与绘制」要求，也需人工）：

| # | 项目 | 操作 | 预期 |
|---|---|---|---|
| 11 | 块视觉真机可见 | 打开示例文档通览 | 列表圆点/序号/复选框、引用通宽背景+左竖线、代码块通宽背景（含开闭栏行）、分隔线横线全部可见 |
| 12 | 暗色模式配色 | 系统外观切到暗色 | 上述块视觉配色随之变暗，无亮色残留 |
| 13 | 外观热切换 | App 打开时切换系统外观 | 已排版区域的块视觉立即跟随，不需要滚动或编辑触发 |

第 12/13 项若失败，即确认 M2-6 的隐患在真机成立，请在《M2 评价报告》§6.4 回填「真机确认：失败」。

### 9.5 M0 的 gate 结论如何更新

三个任务全部完成后：

- 若人工项 1/2/7/9 全部通过 → M0 结论改为「**通过**」，删除「有条件」表述；
- 若第 1 项（零宽留白）或第 2 项（IME）有明显问题 → 按 v0.3 §4.2 的降级路径执行（marker 改弱化色 + 小字号，保留可预测宽度），并在本报告记录降级决定与交互规范；
- 第 11 项失败 → 属于 M2 回归，回到《M2 评价报告》§3 排查，不要改 M0 结论。
