# M0 技术验证报告

- 日期：2026-08-26
- 范围：v0.2 方案 §06 中 M0 的 go/no-go gate
- 结论：**有条件通过（PASS with manual checks）** —— 自动化验证全绿；零宽 marker 的视觉、IME、VoiceOver 三项需人工验收，见文末清单。

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
2. **M2 已完成（2026-08-26）**：swift-markdown 语义层（链接锚点 + 行级块分类，与扫描器做差异测试）；行内链接（标签着色 + 下划线 + `.link` 点击打开 + 语法隐藏/回显）；CommonMark 式强调 run 分析（`*a **b** c*`、`***` 正确，含 mod-3 规则）；有意偏离：CJK/符号按标点类参与 flanking（`**强调**直接` 可加粗，拉丁词内 `a*b*c` 保持字面量）。测试升至 69 项（7 套件）。
3. M3 光标交互：marker 回显手感打磨、方向键与鼠标命中、源码模式切换；之后 M4 块行为（列表续行/退出、标题行为、自动配对）。
