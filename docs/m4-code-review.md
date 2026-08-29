# M4 编辑行为 · 代码审查缺陷清单

**审查对象**：2026-08-28 的未提交改动（`git status` 快照）

```
 M Editor/EditorTextView.swift         (+136)
 M Editor/EditorView.swift             (+11)
 M Rendering/BlockLayoutFragment.swift (+33)
 M docs/tech-plan.{md,html}
?? Editor/TypingBehaviors.swift        (新增)
?? MuseTests/TypingBehaviorsTests.swift (新增)
```

**审查方式**：多角度静态审查 + 在真实 AppKit / TextKit 2 上跑探针实测。下文标注「实测」的数字都是跑出来的，不是推断；标注「待确认」的条目是纯代码推理，动手前请自己复现一次。

> **方法论（三轮复审的血泪教训，对复审方同样适用）**：不要凭读代码断言行为或性能，一律先跑。本清单的复审过程中，「`PendingPair` 引入按键性能回归」和「词前配对行为失去测试守卫」两条都是读代码推出来的、看着无懈可击，实测分别是 0.100ms vs 0.088ms（无回归）和 16 个失败断言跨 4 个测试（守卫完好）。两条都已撤回。

**本文件是给修复方的工单。** 四条硬性约束：

1. **`## 不要修改` 一节里的内容是误报**，已用实测推翻。不要「顺手修」，会引入回归。
2. **不要新增第四套 Markdown 匹配器。** `Parsing/TokenScanner.swift:7` 已经写了「不再维护第二套 CommonMark 匹配器」，缺陷 8 正是违反了这一条。
3. **缺陷 1 和缺陷 15 必须一起修**。测试 15 是自证式的（断言 `f(x) == f(x)`），只修几何、不修测试，等于把同一个洞留着。
4. **`## 语义决策` 的 D1 / D2 / D3 已拍板，按决策执行**，不要自行改变方案；有异议先说明理由。D3 为暂定，其「已知残留」是知情接受的，不要顺手去修。

---

## 构建与验证基线

项目使用 Xcode 16 的 `PBXFileSystemSynchronizedRootGroup`（`project.pbxproj` 里有 8 处），源码目录下的新文件**自动进编译**——`Editor/TypingBehaviors.swift` 和 `MuseTests/TypingBehaviorsTests.swift` 虽然还没进 git，但已经在构建里。**不要修改 `Muse.xcodeproj/project.pbxproj`。**

```sh
# 相关套件（0.1s 级）
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/TypingBehaviorsTests

# 全量
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'
```

**当前基线（2026-08-28，缺陷 18 收尾后实测）**：全量 **186 tests / 10 suites** 全绿。缺陷 1–4、6–18 已修复；缺陷 5 为**部分修复**（见 D3）；缺陷 13 暂缓（等 D3 定局）。

> ⚠️ 缺陷 7 和 12 的错误行为仍被 `TypingBehaviorsTests.swift:34` 写成期望值。按 **D1 决策 (a)**，该 case 的期望值要改成 `"- [X] \n- [X] done"`。

**每条缺陷的修复都必须做一次变异验证**：先把 bug 注入回去，确认新测试变红；再改回正确版本，确认变绿。注入 bug 后测试仍然是绿的，说明测试无效，重写。

**变异验证要双向做**：不仅要注入「偏移错了」，还要注入「范围放大了」。P0 复审就是这样发现缺陷 16 的——原 bug（24pt 偏移）被抓，但 `insetBy(dx: -200)` 这种把命中框放大到吞掉整行的变异完全不被抓。

---

## P0 · 已完成并复审通过（2026-08-28）

缺陷 1 / 15 / 2 已修复，独立复审确认：

| 项 | 实测值 |
|---|---|
| 实际绘制的 ☐ 墨迹（位图扫描） | x ∈ `[4.75, 12.75]` |
| `taskCheckboxHitTarget().frame` | x ∈ `[0.29, 17.91]` |
| 正文起始 x | `29.0`（= `fragment.layoutFragmentFrame.minX`） |
| 点击探针 | x=5、10 命中；x=0、18、22、26、30、40、60 均 `nil` |

- 缺陷 1：改为 `listMarkerFrame(at: layoutFragmentFrame.origin)`，命中框正确包含真实墨迹。
- 缺陷 2：改为 `textLayoutFragment(for:)` 单点定位，全文 `.ensuresLayout` 枚举消失；`usageBounds` 爆量与 +91MB 常驻在机制上已不可能。原「越界 guard 返回 `false` 中止枚举」的歧义随之消失（现为 `return nil`）。
- 缺陷 15：`markerInkBounds` 在 `layoutFragmentFrame.origin` 处绘制（无 shim 偏移），扫真实墨迹，四边断言包含关系，用墨迹中心驱动点击，偏移硬编码 `{9, 1}`。

**测试灵敏度（实测变异区间）**：`+16pt`/`+24pt` 抓到，`+8pt` 抓到，`+4pt` 及以下抓不到——左侧富余 `4.75 − 0.29 = 4.46pt`，小于它的偏移被 `insetBy(-3)` 的容差吸收，且此时墨迹仍在命中框内、功能正常。这个下限是可接受的：测的是可点击性，不是坐标。**但放大方向完全无守卫，见缺陷 16。**

---

## 语义决策（2026-08-28）

以下三条原先有多种合理语义，现已拍板。实现方按决策执行，**不要自行改变方案**；如果认为决策有问题，先说明理由，不要直接改。D1 / D2 为终局决策，**D3 为暂定**。

### D1 · 从已勾选任务项的中间按 Enter（对应缺陷 7）

`- [x] buy milk`，光标在 `buy` 之前，Enter 应该得到什么？

| 方案 | 结果 | 评价 |
|---|---|---|
| **(a) 新项继承原状态** | `- [x] ` + `- [x] buy milk` | 两项都已完成。语义上「拆分一个已完成的任务」得到两个已完成任务，符合直觉；但用户拆分往往是为了把未做的部分分出来。 |
| **(b) 原行保状态，新项用 `[ ]`** | `- [x] ` + `- [ ] buy milk` | **这正是当前的错误行为**：已完成项变成空的已勾选任务，真正的任务静默回退为未完成。不可接受。 |
| **(c) 仅行尾续行才产生新项** | 中间拆分时不走续行，落回 `super`（插入裸换行） | 最保守，不会猜错语义；代价是中间拆分完全没有列表续行辅助。 |
| **(d) 原行清空状态，新项继承** | `- [ ] ` + `- [x] buy milk` | 把「完成」跟着文本走。逻辑最自洽，但用户会看到第一行的勾突然消失。 |

倾向 **(a)**：改动最小（续行前缀里的状态字符从原行读取，而不是写死 `[ ]`），且不会静默改变任何已有文本的完成状态。

**决策：(a) 新项继承原状态**（2026-08-28 定）

得到 `- [x] ` + `- [x] buy milk`。空项显示为已勾选，视觉上有点怪，但这是刻意的权衡：**任何已有文本的完成状态都不会被静默改动**。实现上是一处改动——`listPrefix` 里 `continuation` 的状态字符从 `match.range(at: 4)` 捕获的原文读取，不要写死 `"[ ]"`。

**同步修改**：`docs/tech-plan.md`（`:325` 附近的任务 checkbox 语义）、`MuseTests/TypingBehaviorsTests.swift:34`（该 case 现在的期望值 `"- [X] \n- [ ] done"` 要改成 `"- [X] \n- [X] done"`，注意大小写按原文保留）

### D2 · 有序列表源码序号（对应缺陷 10）

`1. a\n2. b`，光标在第一行行尾，Enter 之后源文件里应该是什么？

| 方案 | 结果 | 评价 |
|---|---|---|
| **(a) 插入后重排后续项序号** | `1. a` / `2. ` / `3. b` | 最贴近用户预期，源码与渲染一致。代价：一次 Enter 变成多行编辑，整段重排**必须并入同一个 undo group**（见缺陷 3），且要正确界定「同一列表」的边界（缩进层级、中间空行、被段落打断）。 |
| **(b) 沿用上一项的序号** | `1. a` / `1. ` / `2. b` | CommonMark 允许全用同一序号，渲染仍是 1/2/3。改动极小。源码里 `1` 也会重复出现——但 `1.` 重复在手写 Markdown 里是常见惯例，读起来像故意的，而 `2.` 重复读起来像 bug。 |
| **(c) 现状（+1 不重排）** | `1. a` / `2. ` / `2. b` | **当前的错误行为**：源码出现重复序号 1/2/2，而渲染显示 1/2/3。屏幕上看不出来，只在源码模式（⌘/）或外部编辑器里暴露。 |

**决策：(b) 沿用上一项序号**（2026-08-28 定）

`continuation` 用 `numberText` 原样，不做 `number + 1`。渲染仍由 AST 重新编号（`Rendering/RenderEngine.swift:342` 写入 `.museListNumber`），所以屏幕上仍是 1/2/3。这条决策**解除了缺陷 10 对缺陷 3 的依赖**——(a) 方案的整段重排才需要 undo group，(b) 不需要，所以缺陷 10 可以独立于缺陷 3 修。

前导零问题仍要处理：`String(number + 1)` 会把 `01.` 变成 `2.`。选了 (b) 之后直接沿用 `numberText` 原文，前导零自然保留，`Int` 解析只用于校验。

**同步修改**：`docs/tech-plan.md`（列表续行语义）

### D5 · CRLF 行终止符（对应「其余已确认问题」）· 已实现

**决策：读入归一到 LF、记住主流终止符、写回还原**（2026-08-28 定）

`Document/MuseDocument.swift`：`LineEnding` 枚举（`Character` rawValue，CRLF 是单个字符簇）+ `dominantLineEnding(in:)`。

参考 CotEditor（`coteditor/CotEditor`）后修正了两点：

1. **多数投票，不是首次出现。** 全文用官方 `NSString.enumerateSubstrings(.byLines, .substringNotRequired)` 扫出每个终止符，按出现次数取主流，平票取最早出现。原先写的「`contains("\r\n")` → 整个文件按 CRLF 写回」有保真 bug：一个 99% 是 LF、只有一处 CRLF 的文件会被整体改写。
2. **一律走 `.literal` 选项。** `"\r\n"` 在 Swift 里是**单个 `Character`**，默认字符簇语义下 `contains("\r")` 对 CRLF 文本返回 false、`replacingOccurrences(of: "\n")` 也匹配不到 CRLF 里那个 LF。

Foundation **没有**「文档行终止符」的官方 API——CotEditor 也是自己写 code-unit switch 补这个缺口。它选的是相反的存储策略（存原样、在插入边界转换），代价是每个 `NSRange` 计算都要处理「CRLF 占 2 个 UTF-16 单元且不可切开」；对这个逐标量建索引的代码库改动面太大。**已知代价**：混合终止符的文件会被统一成主流那一种。

### D6 · ⌥Return / ⌃Return / ⌃O · 已实现

**决策：一律插入普通 `\n` 且不续行（逃生舱）**（2026-08-28 定）

实测确认：`insertLineBreak`（⌃Return）原生实现插入的是 **U+2028**（`U+0061 U+2028`），cmark 不认它是换行且会原样写进磁盘——必须覆写。而 `insertNewlineIgnoringFieldEditor`（⌥Return、⌃O）本来就插普通 `\n`，无需改动。

同批把 Enter 入口从 delegate 的 `doCommandBy` 搬到 `EditorTextView.insertNewline(_:)` 覆写并删掉 delegate 方法：AppKit 在执行 selector 前调 delegate，两者并存会导致续行跑两次或永不触发。**顺带收益**：delegate 路径此前零测试覆盖（25 个构造点无一设 delegate）。

### D3 · 自动配对的开启条件（对应缺陷 5）· **暂定**

`*` / 反引号在什么位置才开配对？三个候选谓词跑 10 个用例的结果（实测）：

| 谓词 | 不符期望数 |
|---|---:|
| 现状之前（两侧都非字母数字） | 9 |
| 仅「右侧非空白/行尾」 | 1（会在词内 `wo\|rd` 开配对，违背该文件声明的保守意图） |
| **右侧非空白/行尾 且 左侧非字母数字**（两条件） | 0 |
| 再加「右侧非字母数字」（三条件） | 0，但自动配对只在右侧紧跟标点时触发，单键配对形同废除 |

**决策：两条件版，暂定接受词前/句中插入仍会开配对**（2026-08-28 暂定）

已实现（`Editor/TypingBehaviors.swift:144`）。实测行为：

| 光标位置 | 行为 |
|---|---|
| `word\|`（行尾）/ `wo\|rd`（词内）/ 空文档 | 不开 ✓ |
| `\|(x)`（标点前） | 开 → `**(x)` ✓ |
| `\|word`（词前） | **开 → `**word`** ← 已知残留 |
| `a \|b`（句中插入） | **开 → `a **b`** ← 已知残留 |

**知情接受的代价**：在一句话中间把光标放到某个词前打 `*`（例 `The cat sat` 放到 `cat` 前）会得到 `The **cat sat`，多一个星号要手删。这与缺陷 5 原本的 `2 * 3` → `2 * 3*` 是同一形状，只是触发条件从「行尾」变成「后面还有文字」。

**为什么仍接受**：三条件版会让单键配对只在标点前触发，等于废掉该功能，并连带作废第二轮的 `pendingPair` / 跳过闭合符 / `**` 升级与缺陷 11 的 deleteBackward。

**该行为已被测试钉住**（实测：注入三条件版产生 **16 个失败断言、跨 4 个测试**）：
`pairOpensSkipsCloserAndUpgradesBold:211`、`editorTextViewUpgradesThenSkipsBothBoldClosers:339`、`editorDeletesOwnedSingleMarkerPairAsOneStep:357/366`、`editorDeletesOwnedBoldMarkerPairAsOneStep:379/383`。所以改动这个谓词不会静默通过 CI。

**重新审视的触发条件**：真实使用中如果「句中插入时多出分隔符」变成实际困扰，就升级到 D3 乙——单键配对整个去掉、只保留选区包裹，同时移除上述四个测试所守护的行为。

---

## 修复顺序（按实测收益排序）

| 阶段 | 缺陷 | 理由 |
|---|---|---|
| ~~**P0**~~ | ~~1 + 15, 2~~ | ✅ 第一轮完成并复审通过（2026-08-28） |
| ~~**P0 遗留**~~ | ~~16~~ | ✅ 第二轮完成并复审通过：`insetBy(dx: -30)` 变异现产生 4 个失败断言（上一轮为 0） |
| ~~**P1**~~ | ~~3, 4~~ | ✅ 第二轮完成并复审通过：全量 133 tests 通过，无按键性能回归 |
| ~~**P1**~~ | ~~6, 7, 10, 11, 12~~ | ✅ 第三轮完成并复审通过：全量 139 tests，12 组双向变异全部变红 |
| **P1（部分）** | 5 | 部分修复。行尾类误报已清零，**词前/句中插入类仍存在**，按 D3 暂定接受 |
| ~~**P2**~~ | ~~8, 14~~ | ✅ 第四轮完成：全量 142 tests。**但缺陷 8 的修复引入了缺陷 17** |
| ~~**P1**~~ | ~~17~~ | ✅ 第五轮完成：三层判定 + 委托 swift-markdown 单行解析 |
| ~~**P3**~~ | ~~9 + 其余已确认问题~~ | ✅ 第五轮完成（几何去重、CRLF、⌃Return、字符簇词边界、小清理） |
| **P2/清理** | 13 | 暂缓：它重构的正是 D3 乙方案会删掉的状态机 |
| **不在 M4 范围** | 18 | 装饰范围退化导致渲染滞后，属 M2 管线 |

---

## P0

### 1. 复选框点击区整体偏右 24pt，与绘制的字形零重叠

**位置**：`Rendering/BlockLayoutFragment.swift:287-291`

```swift
let drawPoint = CGPoint(
    x: layoutFragmentFrame.minX + info.markerLaneWidth,   // ← 多加了一个 marker lane
    y: layoutFragmentFrame.minY
)
guard let markerFrame = listMarkerFrame(at: drawPoint) else { return nil }
```

**现象**：点击视觉上的 ☐ 返回 `nil`（无反应）；点击列表项正文的头几个字符反而会切换勾选状态。整个 M0 验收项和 `docs/tech-plan.md:325` / `:532` 的描述目前都是假的。

**根因**：`ListMarkerGeometry.frame` 内部（`BlockLayoutFragment.swift:124`）已经做了 `x: fragmentPoint.x - markerLaneWidth - markerOriginOffsetX`——marker 本来就画在锚点左侧的固定 lane 里。所以传入点必须是 **fragment 原点**，不能预先加 lane 宽度。这个 `+ markerLaneWidth` 是从测试专用的位图垫片抄来的：`MuseTests/RendererTests.swift:761-764` 有 `frame.origin.x + 24`，注释明确写着「Give this isolated bitmap the same leading room that the real text view's inset provides」——那是孤立位图没有容器偏移才需要的补偿，生产路径不需要。

**实测**（深度 1 的任务项，320pt 容器）：

| | x 区间 |
|---|---|
| 实际绘制的 ☐ 墨迹 | `[3.3, 14.9]` |
| `taskCheckboxHitTarget().frame` | `[24.3, 41.9]` |

`draw(at:in:)` 收到的 point 是 `(0,0)`，而 `layoutFragmentFrame.minX == firstLineHeadIndent + lineFragmentPadding == 29.0`。容器坐标 = 绘制坐标 + `layoutFragmentFrame.origin`，因此传 `layoutFragmentFrame.origin` 得到的正是容器坐标系下的真实字形框（`29 - 24 - inkOriginX(≈1.7) ≈ 3.3`，与实测墨迹左沿吻合）。

**改法**：

```swift
guard let markerFrame = listMarkerFrame(at: layoutFragmentFrame.origin) else { return nil }
```

调用方 `EditorTextView.taskCheckboxToggleRange` 已经把点击点换算到容器坐标（`point - textContainerOrigin`），所以只要几何回到容器坐标系就自洽了。

**验证**：先按缺陷 15 改测试，再跑。

---

### 15. 复选框命中测试是自证式的，无法发现任何坐标错误

**位置**：`MuseTests/TypingBehaviorsTests.swift:210-261`（`taskCheckboxUsesRealFragmentHitFrameAndUndo`）

**现象**：测试自己调用 `taskCheckboxHitTarget()` 拿到 frame，加上 `textContainerOrigin`，点 `frame.midX/midY`，然后断言 `taskCheckboxToggleRange`（内部重算同一个 frame）与之一致——即 `f(x) == f(x)`。矩形偏多少都是绿的，唯一的反例只有 `CGPoint(x: 2, y: 2)`。缺陷 1 就是这样通过 CI 的。

次要问题：`:229-245` 把生产代码里的 `offset(from:to:)` 换算整段复制了一遍，所以文档偏移算错时，期望值会以同样的方式算错，同样发现不了。

**改法**：照 `MuseTests/RendererTests.swift:788` 起的 `markerInkMinX` 的写法——那里已经有正确的模式：

1. 在 `fragment.layoutFragmentFrame.origin` 处把 `drawBlockVisuals` 画进位图；
2. 扫出真实墨迹的包围盒；
3. 断言墨迹盒**包含在** `taskCheckboxHitTarget().frame` 内（或至少中心点落在 frame 内）；
4. 再用墨迹中心点驱动 `toggleTaskCheckbox`，断言源文本改变 + 一次 ⌘Z 复原。

文档偏移那段不要复制，改成对已知源串的字面断言（例：`"前😀文\n\n- [ ] task"` 里状态字符的偏移是固定值，直接写死）。

---

### 2. 每次左键点击都强制全文布局

**位置**：`Editor/EditorTextView.swift:176-180`

```swift
layoutManager.enumerateTextLayoutFragments(
    from: layoutManager.documentRange.location,     // ← 从文档头开始
    options: [.ensuresLayout]                       // ← 且强制布局
) { fragment in ... }
```

**现象**：`mouseDown` 在 `super.mouseDown` 之前无条件调用它，且闭包在**未命中时返回 `true`**（继续枚举），所以任何一次落在非复选框位置的普通点击都会一路布局到文档末尾，然后光标才移动。

**实测**（单次普通点击的耗时）：

| 文档大小 | 冷启 | 热态 |
|---|---|---|
| 20 KB | 35.7 ms | 10.2 ms |
| 200 KB | 231.7 ms | 74.2 ms |
| 1 MB | 1135 ms | 374 ms（24,692 个 fragment） |

另外还有**永久性的 +91MB 常驻内存**（仅视口布局 2.8MB → 全文布局后 93.8MB），且首次点击后 `usageBounds` 高度跳到 429,599pt。作对比：`textLayoutManager.textLayoutFragment(for:)` 在 1MB 文档上是 **0.045–0.051 ms**，快约 7300 倍。

**改法**：直接定位命中点所在的单个 fragment，不要枚举：

```swift
guard let fragment = layoutManager.textLayoutFragment(for: containerPoint) as? MuseLayoutFragment,
      let target = fragment.taskCheckboxHitTarget(),
      target.frame.contains(containerPoint)
else { return nil }
```

注意命中框做了 `insetBy(dx: -3, dy: -2)` 外扩，可能略微超出 fragment 自身的行框，边界上要么容忍这几 pt，要么额外查一次相邻 fragment——但**绝不要**退回全文枚举。

**顺带**：`:198` 的越界 `guard` 返回 `false`，语义是「中止枚举」而不是「跳过这个 fragment」；改成单点定位后这个歧义自然消失。（✅ 已随 P0 修复，现为 `return nil`。）

---

## P0 遗留 · 已完成（2026-08-28 第二轮）

### 16. 复选框命中测试不守卫「命中框过大」的方向

**位置**：`MuseTests/TypingBehaviorsTests.swift:296-306`

**现象**：重写后的测试断言「命中框包含墨迹」（四边）+「墨迹中心可点击」，这守住了**偏移**方向，但完全没守住**放大**方向。实测变异：

| 变异 | 结果 |
|---|---|
| `insetBy(dx: -30, dy: -2)` | ❌ 测试全绿 |
| `insetBy(dx: -200, dy: -60)` | ❌ 测试全绿 |

`dx: -200` 的命中框会吞掉整行正文和邻行——正是让缺陷 9 变严重的那个方向（链接被劫持、双击选词变成编辑、拖选失效）。测试里唯一的负向控制是 `CGPoint(x: 2, y: 2)`，那个点落在另一行上，靠 fragment 定位就返回 `nil` 了，根本没触及命中框的尺寸。

**改法**：补一条负向断言，点在正文起始之后、确认不切换：

```swift
// 实测：正文起始 x = 29.0（= fragment.layoutFragmentFrame.minX），
// 命中框右沿 = 17.91，中间有 11.1pt 间隙。
#expect(textView.taskCheckboxToggleRange(
    at: CGPoint(x: 29.0 + 4 + textView.textContainerOrigin.x, y: inkCenter.y)
) == nil)
```

更稳的写法是从 fragment 取 `layoutFragmentFrame.minX + textLineFragments.first!.typographicBounds.minX` 得到正文起始 x，而不是写死 29.0——但**不要**把它算进期望值链条里（那会重新变成自证式）；只用它定位「一个肯定在正文上的点」。

**验证**：把 `insetBy(dx: -3, dy: -2)` 改成 `insetBy(dx: -30, dy: -2)`，新断言必须变红。

---

## P1 — ⌘Z 会丢数据

### 3. 没有任何编辑路径建立 undo group，一次 ⌘Z 抹掉整行

**位置**：`Editor/EditorTextView.swift:122`（以及 `:89`、`:160` 三处 `super.insertText`）

**现象**：`docs/tech-plan.md:345` 要求「自动配对、列表续行等复合操作显式组成单个 undo group」，但全树 grep 不到任何 `breakUndoCoalescing` / `beginUndoGrouping`。这些编辑因此被并入前后的打字会话（typing coalescing）。

**实测**（每个按键一个 run-loop turn）：

- 输入 `- item` → Enter（续行）→ `two`，得到 `- item\n- two`；**一次 ⌘Z 结果是空串 `""`**。
- 输入 `a ` → `*`（自动配对），同样一次 ⌘Z 全没。
- 复选框切换之所以侥幸独立，只因为它的 `replacementRange` 与打字位置不相邻。

**改法**：在这三处 `super.insertText` 之前调用 `breakUndoCoalescing()`，并把「替换 + `setSelectedRange`」包在 `undoManager.beginUndoGrouping()/endUndoGrouping()` 里；`setSelectedRange` 之后再 `breakUndoCoalescing()`，防止后续输入又被并进来。

**验证**：把测试里的按键改成每次一个 run-loop turn（现有 `editorTextViewAppliesListEditAndUndoAsOneStep` 在同一 turn 里连续调用，绕过了 coalescing，所以是绿的），断言一次 ⌘Z 只回退到「续行前」而非空串。

---

### 4. 跳过闭合符在任意位置触发，吞掉按键且不产生 undo 步

**位置**：`Editor/TypingBehaviors.swift:111-132`

```swift
let suffixRange = NSRange(location: selection.location, length: min(markerLength, source.length - selection.location))
if suffixRange.length == markerLength, source.substring(with: suffixRange) == marker {
    ...
    return Edit(range: selection, replacement: "", selectionAfter: ...)  // ← 只挪光标
}
```

**现象**：这个判断只看「光标右边的字符是否等于 marker」，不区分是不是编辑器自己插的配对。而它位于 `:137` 的词边界守卫**之前**，所以「保守只在非词边界开配对」的既定意图在这条路径上完全不生效。

- 文本 `*emphasis*`，光标在 0，输入 `*`：文本毫无变化，只是光标跳到 1。`**emphasis*` 这个结果用户永远打不出来。
- 因为 `replacement` 为空、`super.insertText` 被跳过，这一步**不进 undo 栈**。实测：输入 `*`（得 `**`）→ `abc`（得 `*abc*`）→ 再输入闭合的 `*`（被吞），一次 ⌘Z 得到 `**`，`abc` 被销毁。

**改法**：跳过闭合符必须限定为「本编辑器刚刚插入的那个配对」。现有的 `pendingAsteriskUpgrade` 机制已经在做类似的事（但见缺陷 13，它的实现要换成编辑计数器），把跳过闭合符也挂到同一状态上；无状态时不要吞按键，落回 `super.insertText` 原样插入。

---

## P1 — 静默改坏用户文本

### 5. `*` / 反引号被空白包围时也开配对，往正文里塞多余分隔符

**位置**：`Editor/TypingBehaviors.swift:137-141`

```swift
if isAlphanumeric(source.characterBefore(selection.location)) ||
    isAlphanumeric(source.characterAfter(selection.location))
{ return nil }
```

**现象**：只要两侧都不是字母数字就开配对，而空白和行尾都满足这个条件——那些位置永远不可能构成合法的 delimiter run。逐字符跑真实逻辑的结果：

| 输入 | 得到 |
|---|---|
| `* item`（该文件自己的 bullet 正则也认这个） | `* item*` |
| `2 * 3` | `2 * 3*` |
| ` ```swift ` | `` ```swift` `` |
| `see footnote *` | `see footnote **` |

全是日常输入，全都静默多出一个要用户自己发现并删掉的分隔符。

**改法**：见 **D3**（`## 语义决策`）。⚠️ 本条原先写的「后一个字符不能是空白」是**不完整的**——它丢掉了原有的左侧守卫，会让词内 `wo|rd` 也开配对。正确谓词是两条件版：右侧非空白/行尾 **且** 左侧非字母数字。

**状态：部分修复（2026-08-28 第三轮）**。行尾类误报（上表四条）全部清零，实测确认。**词前 `|word` 与句中插入 `a |b` 仍会开配对**，按 D3 暂定知情接受，详见该条。

---

### 6. 行内 Enter 会吃掉光标前的空白，包括 CommonMark 硬换行

**位置**：`Editor/TypingBehaviors.swift:38-42`（`trailingWhitespaceStart` 的调用点）

**现象**：该函数意图是「行尾多余空白不要带到新行」，但在**任意**光标位置都执行，所以从行中间拆分列表项时会连带删掉光标前的空白：

- `- alpha |beta`（光标 8）→ `- alpha\n- beta`，空格被吞。
- `- alpha   |beta` → 三个空格全删。
- `- line one··`（两个尾随空格 = 硬换行）+ Enter → `- line one\n- `，**硬换行被销毁**，上一项的渲染方式静默改变。
- 拆分和删除是同一个不可分的 undo 步，一次 ⌘Z 一起回退，用户看不出发生了什么。

**改法**：加行尾守卫——只在 `relativeCaret == (line as NSString).length` 时才应用 `trailingWhitespaceStart`。

---

### 7. 拆分已勾选项时，勾选状态留在空项上，真正的任务被取消完成

**位置**：`Editor/TypingBehaviors.swift:183`（`continuation: indent + bullet + beforeTask + "[ ]" + afterTask`）

**现象**：`continuation` 把 `[ ]` 写死，而该分支对「光标 >= contentStart」的任意位置都触发：

`- [x] buy milk`，光标在 `buy` 前，Enter →

```
- [x] 
- [ ] buy milk
```

已完成项变成一个空的已勾选任务，真正的任务则静默回退为未完成。

**注意**：`MuseTests/TypingBehaviorsTests.swift:34` 把这个错误结果写成了期望值——

```swift
NewlineCase(source: "- [X] done", caret: 6, expectedSource: "- [X] \n- [ ] done", expectedCaret: 13)
```

测试锁死了错误行为，所以修代码时必须同时改这条 case。

**改法**：按 **D1 决策 (a)**——续行前缀里的状态字符从原行捕获组读取，不要写死 `[ ]`。结果是 `- [x] ` + `- [x] buy milk`。同时改 `MuseTests/TypingBehaviorsTests.swift:34` 的期望值。

---

### 10. 有序列表续行只给新项编号，往文件里写重复序号

**位置**：`Editor/TypingBehaviors.swift:187-197`

**现象**：`1. a\n2. b`，光标在第一行行尾，Enter → `1. a\n2. \n2. b`。屏幕上看不出来，因为 `.museListNumber` 由渲染引擎从 AST 写入（`Rendering/RenderEngine.swift:342`，`BlockLayoutFragment.swift:470` 读取），渲染显示 1/2/3，**而源文件里是 1/2/2**——只在切到源码模式（⌘/）或用别的编辑器打开时才暴露。

次要：`String(number + 1)` 丢前导零（`01.` → `2.`）。

**改法**：按 **D2 决策 (b)**——`continuation` 沿用 `numberText` 原文，不做 `number + 1`。结果是 `1. a` / `1. ` / `2. b`，渲染仍为 1/2/3。沿用原文后前导零自然保留（`01.` 不再变 `2.`），`Int` 解析只保留用于校验。**本条不依赖缺陷 3**（那是 (a) 方案整段重排才需要的）。

---

### 11. 自动配对没有 `deleteBackward` 对应实现，退格留下孤立闭合符

**位置**：`Editor/EditorTextView.swift:94`（`insertText` 覆写旁缺少 `deleteBackward` 覆写）

**现象**：全树没有 `deleteBackward` 覆写，且 `:47` 关了 `smartInsertDeleteEnabled`，AppKit 不会兜底。

- 输入 `*` → `*|*`；退格 → `|*`，留下一个用户没打过的星号。
- 输入 `*` `*` → `**|**`；退格 → `*|**`，三个不配对的星号。
- 反引号同理。
- `editorTextViewUpgradesThenSkipsBothBoldClosers`（`:191`）只正向输入，这条路径零覆盖。

**改法**：覆写 `deleteBackward(_:)`——当光标正好夹在一对刚插入的对称 marker 之间（复用缺陷 4 提到的配对状态）时，一次删掉两侧；否则 `super`。并入同一 undo group。

---

### 12. 全角空格被判为「空项」，整行内容被删

**位置**：`Editor/TypingBehaviors.swift:30`

```swift
if content.trimmingCharacters(in: .whitespaces).isEmpty {
```

**现象**：`CharacterSet.whitespaces` **包含 U+3000（全角空格）和 U+00A0（不换行空格）**（已实测确认），而同文件的 `trailingWhitespaceStart`（`:229`）只认 space/tab。两者不一致的后果：

`- 　`（bullet + 一个全角空格——对这个明确面向中日韩的编辑器来说是日常输入）：`content == "　"`，trim 判为空，`newlineEdit` 于是把整行内容连同刚打的那个字符一起删掉。从网页粘来的不换行空格同理。

**改法**：把判空用的字符集与 `trailingWhitespaceStart` 统一。CommonMark 的空列表项判定只看 space/tab，所以应该收紧 trim 而不是放宽另一侧——用只含 space/tab 的 `CharacterSet(charactersIn: " \t")`。`:63` 的 heading 判空处有同样的问题，一并改。

---

## 第五轮：缺陷 17 / 9 / P3 收尾（2026-08-28 完成）

### 实测的暴露窗口——比原先的对冲说法严重得多

工单原先写「小文档下按键之间的 run-loop 轮次大概足够让渲染追上」。实测「最后一次按键 → `.museBlock` 出现」：

| 文档规模 | 落地耗时 |
|---|---:|
| 20KB | 37.9ms |
| 200KB | **343.3ms** |
| 1MB | **1828.4ms** |

人从打完最后一个字符到按 Enter 通常 100–200ms，所以 **200KB 是常态失败、1MB 是必然失败**。

### 缺陷 17 的最终修法（与原方案有三处不同）

`typingBlockContext` 改成三层：

1. **否决层**：`.museBlock` 为 `codeFence` / `rule` → 拒绝。可靠性来自实测——围栏的属性覆盖整块**含行终止符**，新输入靠 `typingAttributes` 继承，围栏内新起一行打 `- item` 也读得到 `codeFence`。
2. **接受层**：读 `.museListMarkerLocation` / `.museListDepth`。
3. **回退层**：`TypingBehaviors.lineShapeContext` → `MarkdownSemantics.lineBlockKind`（swift-markdown 单行解析，实测 14µs）。

配套：`lineContentIndex` 保证下标落在当前行内容里（修情形 4）。

**与批准方案的三处偏离，都是实测推翻的：**

- **情形 3 没有「修属性优先级」。** `.museBlock` 是单值且驱动互斥视觉分派（`drawDecoration` 对 list 提前返回，否则 switch quote/codeFence/rule），翻转优先级会把 `> - item` 的引用背景换成列表符号——视觉回归而非修复。实测发现结构数据一直是对的：`> - item` 的 `.museListDepth = 1`、`markerLocation = 0`、`markerLength = 4` 完好，quote 只覆盖了 `.museBlock` 一个键。所以改成消费端读权威结构键，视觉与 Parsing/Rendering 零改动。
- **「新鲜包」那一层整块删了。** 变异证明它零差异覆盖（删掉 0 失败断言），而它判断新鲜度的长度相等判据本身就是缺陷 17 的成因之一。删掉后其余守卫反而更承重（围栏否决 2 → 5，缩进守卫 2 → 7）。连带删除 `renderPackageProvider`、`freshPackage`、`blockContext(from:)` 与 `EditorView` 接线。
- **手写的行级 CommonMark 规则全删。** 回退层原先自带 thematic break 正则和 4 空格缩进判定，这既是重复造轮子、也违反硬约束 2。改为委托 swift-markdown 后**更正确**：`>     - item` 手写正则判成列表，官方解析器判成 CodeBlock（引用标记之后的 4 空格仍然开缩进代码块）。

### 第五轮的双向变异结果

| 变异 | 失败断言 |
|---|---|
| 下标退回 `min(location, length-1)` | 2 |
| 删掉行形状回退层 | 4 |
| 移除围栏 / 分隔线否决 | 5 |
| 只留行形状（删三层权威判定） | 7 |
| 把 ThematicBreak / CodeBlock 当成列表 | 11 |
| 不下钻 BlockQuote | 2 |
| 引用前缀去掉（`> # Heading` 劈裂） | 1 |
| ⌃Return 退回原生（U+2028） | 2 |
| `insertNewline` 不接智能续行 | 1 |
| 修饰键退回 `flags.isEmpty` | 3 |
| 去掉 `shouldChangeText` 门禁 | 1 |
| 多数投票退回首次出现优先 | 3 |
| 词边界退回裸 code unit | 3 |

### 几何去重（原计划的「缓存」被实测否决）

计划里写的是加按 `elementString` 身份为键的缓存。实测 **`elementString` 身份不跨光标移动保持**（marker 显隐每次移动都 `addAttributes`，重建文本元素）——而光标移动正是重绘时刻，所以按身份做键每次必 miss，只剩失效风险。

改成**单次调用内去重**：`resolvedMarker()` 一次算出 `ListMarkerInfo` + glyph + font + size + 对齐 + ink 偏移，四个入口共用；`isHidden` 每次重算（两次属性读，便宜且永远正确）。A/B 实测绘制路径 **69.59µs → 35.53µs（约 2 倍）**，`listMarkerFrame` 33.59µs → 26.45µs。

### 其余已完成项

- 缺陷 9：门禁改用官方 `shouldChangeText(in:replacementString:)`（手写 `isEditable` 变异零覆盖——`shouldChangeText` 本来就覆盖它，还额外覆盖 delegate 否决）；修饰键只排除 `[.command, .option, .control, .shift]`；顺序改为先 `makeFirstResponder` 再改文档；修饰键判定提成 `isCheckboxToggleCandidate(_:)` 纯谓词。
  > **测试设计教训**：驱动完整 `mouseDown` 去测「被拒绝的事件」会走到 `super.mouseDown`，那里 AppKit 进入鼠标跟踪循环等一个测试永不发出的 mouse-up——本轮实测让 `xcodebuild` 卡死 8 分钟。测纯谓词。
- `> # Heading` 引用劈裂（D4 之外的独立缺陷）：插入的空行现在带上 `>` 前缀。
- 词边界改用 `rangeOfComposedCharacterSequence`，修掉星际平面字母数字（CJK 扩展 B、数学字母）与组合附加符号的误判。
- `range(of: "[ ]")` 扫两遍合成一次；`elementRange.length` 那次多余的 `offset(from:to:)` 内容树遍历删掉。

---

## M2 渲染管线追加修复（2026-08-28 完成）

### 18. 连续输入时装饰范围退化成整篇，且取消的解析任务继续争抢 CPU

**原位置**：`Document/RenderCoordinator.swift:100`

原实现用 `editsSinceApply > 1` 直接把 dirty range 放大成整篇。连续输入必然命中，因此 200KB/1MB 的属性应用随文档规模线性放大。修复没有直接 union 历史 `NSRange`（那会使用陈旧坐标），而是把 pending dirty 始终维护在当前正文的 UTF-16 坐标系：

- 前方插入：旧 dirty 整体按 `changeInLength` 平移；
- 后方编辑：旧 dirty 坐标不变；
- 相交替换/删除：保留替换区两侧仍存活的边界并收缩；
- 多处编辑：重基后与本次编辑范围合并；
- 只有当前 revision 成功应用后才清空 pending，陈旧结果不能清状态；
- `lastPackage` 与显隐/呈现模式门禁继续绑定到已应用 revision。

实测还暴露了第二个热路径：swift-markdown 的同步 `prepare` 不合作检查 Task cancellation。若每个按键立即启动 detached 解析，零间隔 11 键会同时留下 11 个已经取消、但仍在跑整篇解析的任务。现加 8ms 输入 burst 去抖；被后续按键取消的任务在进入 `prepare` 前退出，只解析最新快照。

**最终证据**：

| 项目 | 结果 |
|---|---:|
| Debug 全量 | **186 tests / 10 suites** |
| Release 200KB 单键 | **54.0ms** |
| Release 200KB 连续 11 键（最后一键 → 属性落地） | **66.7ms** |
| 最终 dirty / 正文 | **12 / 132171 UTF-16 单元** |
| 同一 burst 实际 `prepare` | **1 次** |

**变异验证**：

| 变异 | 被捕获的结果 |
|---|---|
| 恢复整篇 dirty fallback | 性能范围测试失败，单键也重新越过粗门槛 |
| 前方插入不平移旧 dirty | 纯坐标测试 + 真实管线测试失败 |
| 在对应 revision 应用前清空 pending | 连续输入、多处快速编辑与样式断言失败 |
| 每次只保留最后一个 edited range | 连续输入、多处快速编辑与后方样式断言失败 |
| 忽略 debounce 取消 | `parsePreparationCount` 从 1 变 11，性能测试失败 |

保留单个合并范围是当前有意取舍：两个相距很远的编辑会装饰两者之间的行，但正常连续输入保持局部；若未来协同编辑或多光标使离散编辑成为主路径，再升级为多段 range set。

---

### 17. 列表续行依赖渲染属性，新建列表的第一次回车可能不续行

**位置**：`Editor/EditorTextView.swift:119-168`（`typingBlockContext`）、`:137-139`（陈旧判据）

**来源**：缺陷 8 的修复。为了拿到块上下文，`performSmartNewline` 现在要求以下之一成立——(1) 光标处有 `.museBlock` 属性，或 (2) `renderPackageProvider` 返回的包与正文**等长**。两者都不成立时返回 `nil`，`performSmartNewline` 返回 `false`，退化成插入裸换行。

**实测**（用陈旧 provider + 不重渲染隔离出渲染滞后窗口）：

| 场景 | `performSmartNewline()` |
|---|---|
| 普通段落后新起一行打 `- item`，渲染未追上 | **`false` — 不续行** |
| 已渲染的列表行内继续打字（包已陈旧） | `true` — 续行正常（typingAttributes 继承 `.museBlock`） |
| 完全未渲染、无 provider | `false` |

**症状**：新建列表的**第一次**回车不续行；该行被渲染过之后就正常了。因为 AppKit 新输入的文字继承 typingAttributes，在已渲染的列表行里打字能继承到 `.museBlock`，而在段落后新起一行打 `- ` 继承的是段落属性。

**当时的暴露范围判断（历史）**：以上先证明了机制，后续实测确认 20KB/200KB/1MB 都存在可见窗口。缺陷 17 已用实时行形状 + swift-markdown 回退修复；缺陷 18 又把协调器改为当前坐标 dirty range + 8ms burst 去抖，因此这里不再是未测项。

**严重度**：优雅降级（插入普通换行，不丢数据、不改坏文本），所以不是数据安全问题，是核心便利功能的间歇性失效。

**被测试掩盖**：`editorTextViewAppliesListEditAndUndoAsOneStep` 原本逐字输入 `- item` 建立正文（会暴露本问题），第四轮改成预先同步 `engine.render(...)`。改动已被如实披露，但表述为「按设计要求依赖 AST 渲染属性」，未指出这是一个可静默失效的时序依赖。**修复本条时必须恢复一条逐字输入、不预渲染的测试**，否则问题会再次隐形。

**改法方向**（未定，需要先测暴露范围）：

- `package.index.utf16Length == source.length` 这个判据过严也过松：任何变长编辑都会作废整个包，而**等长**编辑（`- ` 替换成 `> ` 恰好等长）却会放过陈旧包导致误分类。
- 当时的 `editsSinceApply` 后来被 `pendingDirtyRange` 取代；后者为 nil 时 `lastPackage` 才与属性层一致。编辑行为最终没有跨层读取这个私有状态，而是使用实时行形状 + swift-markdown 回退消除时序依赖。
- 更彻底的方向：陈旧包仍可信地回答「当前行是否在代码围栏内」这类**块级**问题（缺陷 8 真正要防的就是围栏和 rule），marker 字面值则从实时行文本取。这样既保住块上下文的权威性，又不受渲染滞后影响。

---

## P2

### 8. 续行识别是第三套无块上下文的 Markdown 匹配器

**位置**：`Editor/TypingBehaviors.swift:173-215`（`listPrefix` / `headingPrefix`）

**现象**：纯行级正则，没有块上下文，已确认的误判：

- ``` ``` ``` 围栏**内部**的一行 `- item` 命中 bullet 正则，Enter 往用户代码里注入 bullet；4 空格缩进代码块同理。
- `- - -` / `* * *` 是 ThematicBreak，本代码库已经把它归类为 `.rule`（`Parsing/MarkdownSemantics.swift:160`），却在这里命中 bullet——Enter 把一条分隔线变成列表。
- 反向漏判：`> - item` 是真的列表 token，但正则看不穿 `>`，引用块里的列表拿不到续行。

`RenderCoordinator.lastPackage`（`Document/RenderCoordinator.swift:36`）和 `.museBlock` / `.museList*` 属性都是可达的、且当前**没被用到**。`Parsing/TokenScanner.swift:7` 写着「不再维护第二套 CommonMark 匹配器」。

**改法**：从 `.museBlock` 属性（渲染引擎已写入，与样式状态严格一致）或 `RenderCoordinator.lastPackage` 的 AST 读块类型，先判定「当前行属于哪个块」，只在 list / heading 块里走续行；代码块、rule 一律落回 `super`。行级正则可以保留用于取 marker 的字面文本（indent / bullet 字符 / 间距），但**块类型必须来自 AST**。

**顺带**：`firstMatch`（`:217`）每次 Enter 最多重新编译 4 个正则——提成 `static let` 预编译；且 `try?` 会把「正则写错」降级为「行为静默消失」，改成 `try!` 或在预编译处 assert。

---

### 9. 复选框命中后 `mouseDown` 不调用 `super`，丢掉一整套原生行为（P0 修复后已降级）

**位置**：`Editor/EditorTextView.swift:138-146`

> **2026-08-28 复审更新**：本条原先的严重度建立在「命中区与正文重叠」之上。缺陷 1 修完后实测：命中框右沿 `17.91`，正文起始 `29.0`，**中间有 11.1pt 间隙，不重叠**。因此以下三条场景**已不成立**，不必再处理：
> - ~~`- [ ] [spec](https://…)` 里点链接会切换复选框~~
> - ~~双击选词时 `clickCount == 1` 那次 down 就已经改了文档~~
> - ~~在正文上按下拖动会触发切换~~
>
> 本条降级至 P3 量级。

**仍然真实的部分**：命中分支直接 `return`，跳过 `super.mouseDown`，因此丢掉光标定位、拖拽选择的 tracking loop、autoscroll，以及 `isEditable` 门禁。剩下两个可复现的问题：

1. **`isEditable` 未检查**（真实缺陷）：`window?.makeFirstResponder(self)` 在 `super.insertText` **之后**才执行，所以从侧栏点过来的聚焦点击会在没有任何 `isEditable` 检查的情况下改文档。
2. **8×13pt 区域内无法起选**：在复选框那一小块上按下并拖动，切换发生且不产生选择拖拽。影响面很小。

**改法**：命中判定只做「几何 + 状态字符合法」，不要在 `if` 条件里改文档（现在 `toggleTaskCheckbox` 是在条件求值时产生副作用的）。顺序应为：先 `makeFirstResponder`，检查 `isEditable`，再执行切换；未命中或不可编辑时无条件 `super.mouseDown`。

**`flags.isEmpty` 的问题现在是活的**：缺陷 1 已修，`:140` 的 `flags.isEmpty` 遇到 Caps Lock 以及 `.function` / `.numericPad` 会为假，静默吞掉复选框点击。改成只排除 `[.command, .option, .control, .shift]`。

---

### 13. 配对状态用整篇文档字符串快照做失效判定（数据已于 2026-08-28 复测修正）

**位置**：`Editor/EditorTextView.swift:14`（`pendingAsteriskUpgrade`）、`:21-27`（`PendingPair.source`，第二轮新增）、`:118-119`

```swift
&& pendingAsteriskUpgrade?.source == string          // O(文档) 的 == 比较
let activePair = pendingPair?.source == string ? pendingPair : nil   // 同上
```

**实测（2026-08-28，第二轮复审重测，替换先前的错误数字）**：

| 项 | 200KB | 1MB |
|---|---:|---:|
| 裸 `snapshot == string`（内容相同） | 3.26ms | **16.02ms** |
| 裸 `snapshot == string`（内容已不同） | — | 8.26ms |
| 创建快照 `let s = string` | 0.000ms | 0.000ms |
| **端到端单键（普通输入）** | — | **0.088ms** |
| **端到端单键（在自动配对内部）** | — | **0.100ms** |

三条结论：

1. **裸比较确实贵**：1MB 上 16.02ms，恰好吃掉 `docs/tech-plan.md:365` 的整个 16ms 预算。先前文档写的 42.6ms 高估约 2.7 倍，已作废。
2. **但端到端按键并不慢**：0.088–0.100ms，且在配对内部逐字输入与普通输入无差异。说明这个比较在实测路径上没有付全价。**这两个测量未能调和成一个可靠的机制解释**——不要在此基础上编造原因，也不要假设它一定安全。
3. **不存在「常驻第二份正文副本」**：创建快照测得 0.000ms，是惰性/写时复制。先前文档的内存说法已作废。（快照本身仍是**真值语义**——等长替换后快照保留原内容，见 `## 不要修改`。）

**因此本条降级**：从「已证实的打字卡顿」改为「输入路径上的潜在地雷」。仍然值得修，理由是把一个 16ms 量级的操作留在按键路径上很脆弱，而不是它当前正在卡。

**现象（正确性，仍然成立）**：标记只在 `insertText` / `mouseDown` / `performSmartNewline` / `toggleTaskCheckbox` 里清除。方向键、删除、undo，以及 `RenderCoordinator` 的程序化 `setSelectedRange` 都不清。实测：输入 `*`，按 → 再按 ←，再输入 `*`，会升级成 `****`；而同样的文档和光标位置若不经这套「预热」到达，走的是跳过闭合符的路径——同一状态两种行为。

**改法**：用**单调递增的编辑计数器**代替字符串快照（`textStorage` 的 `didProcessEditing` 里自增），比较退化为 O(1)。第二轮之后收益更大：`pendingAsteriskUpgrade` 和 `pendingPair` 两套状态各存一份快照、各有一条 `if` 链，换成计数器可以**合并成一套机制**，顺带把 `insertText` 那约 100 行压回可读长度。`pairEdit` 在 `:119` 已经会结构性地重新校验 `*|*` 的形状，不需要整篇文档来确认「文档没变」。同时把清除点补齐：覆写 `setSelectedRange(_:affinity:stillSelecting:)` 是最省事的挂点。

---

### 14. `performSmartNewline` 缺少 `insertText` 里那条多选区守卫（待确认）

**位置**：`Editor/EditorTextView.swift:82`

**现象**：`insertText` 在 `:96` 有 `selectedRanges.count == 1` 才继续，但 `performSmartNewline` 只检查 `hasMarkedText()`，然后读 `selectedRange()`——那只返回主选区。多插入点（Option 拖拽）落在列表项里时，Enter 只续行第一个，`:90` 的 `setSelectedRange` 把其余所有选区折叠掉，其他位置的换行全部丢失；返回 `false` 本来会让 AppKit 在所有插入点正常插入。

本次 diff 当时新增的 `docs/tech-plan.html` 明确声称「多选区…均回退给系统」。（该文件已于 2026-08-29 删除，技术方案只保留 `.md` 一份。行号 `:111` 在任何已提交版本里都对不上这句，写工单时引的应是未提交的中间状态，已无法核实。）

**改法**：把 `selectedRanges.count == 1` 加进 `:82` 的 `guard`。

---

## 不要修改（已实测推翻的误报）

### ✗ 「`pendingAsteriskUpgrade` 的守卫是失效的 / `NSTextView.string` 是活代理」

有观点认为 `NSTextView.string` 返回活对象，所以存下来的 `source` 与实时缓冲区别名，`==` 比较退化成长度检查。**这是错的。**

初次探针用了 3 字符字符串（Swift 内联存储）而产生误判；在 195,000 长度的文档上复测：存下来的 Swift `String` 跨编辑保持自己的前缀和 count，`captured == tv.string` 为 `false`，并且能正确识别**等长替换**。守卫在功能上是正确的。

混淆源自一个真实但不同的事实：`as NSString` **强转**确实拿到活对象（实测显示 `"ZZZAAA"`），但桥接后的 Swift `String` 是真快照。

**连带结论**：`Document/RenderCoordinator.swift:105`（`let snapshot = storage.string`，在 `:110` 传进 `Task.detached`）**不存在**数据竞争，不要改。

（缺陷 13 是要改的，但理由是**性能和标记生命周期**，不是正确性——修的时候别顺着「守卫失效」的思路走。）

### ✗ 「切换复选框的字符会继承光标的 `typingAttributes`」

两个审查角度独立提出，并给了一个「H1 字号经 `fixParagraphStyleAttribute` 渗进任务段落导致闪烁」的说法。**实测否定**：把 `typingAttributes` 设为 28pt，再往 0.1pt 的 marker run 里插入，切换后该位置的字号是 **0.1pt**。`insertText(_:replacementRange:)` 继承的是**被替换区间**的属性。没有闪烁，不需要处理。

---

## 其余已确认问题（P3，可选）

- **`isAlphanumeric`（`TypingBehaviors.swift:256`）代理对盲**：`UnicodeScalar(unichar)` 对代理码元返回 `nil`，于是 emoji 后面会开配对，而字母和 BMP 内的中日韩字后面不会——判定方向正好反了。改用 `substring` 取完整字符簇。
- **智能换行只挂在 delegate 钩子上**（`EditorView.swift:67`）：`EditorTextView.make` 的任何其他宿主都会静默失去列表续行；且 ⌥Return / ⌃Return 绕过它。考虑改成覆写 `insertNewline(_:)`。
- **heading 分支其实没拆标题**（`TypingBehaviors.swift:60-77`）：它在标题**上方**插一个空行并把光标停在那儿，与 `docs/tech-plan.md:322` 的描述矛盾。要么改实现，要么改文档。
- **CRLF 文件**：Enter 注入裸 `\n`，而 `MuseDocument` 读写都不做行尾归一化，保存后行尾混用。
- **`MuseLayoutFragment` 上四个入口重复推导同一份几何**（2/3/4/5 次 `ListMarkerInfo` 构造）：约占修完缺陷 2 后单次点击残余成本的 96%，并让 marker 重绘开销大致翻倍。提取一个按 fragment 缓存的几何值。
- **`taskCheckboxHitTarget` 里 `range(of: "[ ]")` 调了两次**（`BlockLayoutFragment.swift:296-298`）：先判断再取值，合成一次。
- **`elementRange.length` 算了但没用**（`EditorTextView.swift:192-196`）：`offset(from:to:)` 不便宜，直接删。

---

## 附录 · 派活用的 prompt

下面这段可直接交给编码 agent（Codex 等）。**每轮只改「本轮范围」那一段**：P0 → P1 → P2 → P3，一轮一审。

````text
任务：修复 Muse（macOS / Swift / TextKit 2 Markdown 编辑器）在 M4 编辑行为改动中的缺陷。

仓库：/Users/fulei/workspace/muse   分支：main（改动尚未提交）

第一步：完整读 docs/m4-code-review.md。那是本次任务的权威工单，包含 16 个已确认
缺陷，每条都有位置、代码片段、现象、实测数据、建议改法和验证方式。所有行号已核对
过。不要凭这段 prompt 的概述动手，以文档为准。

--- 本轮范围 ---

第一轮（1/15/2）、第二轮（16/3/4）、第三轮（5/6/7/10/11/12）已完成并复审通过，
不要再动。本轮做 P2：

  缺陷 8  Editor/TypingBehaviors.swift:173-215  续行识别是第三套无块上下文的匹配器
  缺陷 14 Editor/EditorTextView.swift:82        performSmartNewline 缺多选区守卫

缺陷 8 是本轮的主体，也是整份清单里唯一涉及架构的一条：必须从 .museBlock 属性或
RenderCoordinator.lastPackage 的 AST 读块类型，禁止再加正则。详见该条与硬性约束 2。

缺陷 13（合并 pendingPair 与 pendingAsteriskUpgrade 为编辑计数器）、缺陷 9
（isEditable 门禁与 flags.isEmpty）及「其余已确认问题」本轮不要碰。

--- 硬性约束 ---

1. 文档「## 不要修改」一节列了三项误报，都已用真实 AppKit 探针实测推翻：
     - pendingAsteriskUpgrade 守卫失效说 / NSTextView.string 是活代理说
     - Document/RenderCoordinator.swift:105 的数据竞争说
     - 切换复选框继承 typingAttributes 说
   不要「顺手修」这三项，会引入回归。如果你的分析与文档结论矛盾，先写出你的复现
   步骤给我看，不要直接改。

2. 不要新增第四套 Markdown 匹配器。Parsing/TokenScanner.swift:7 明确写着「不再
   维护第二套 CommonMark 匹配器」。（这条主要约束缺陷 8。）

3. 不要修改 Muse.xcodeproj/project.pbxproj。项目用 Xcode 16 的
   PBXFileSystemSynchronizedRootGroup，源码目录下的新文件自动进编译。

4. 文档「## 语义决策」的 D1 / D2 已拍板，按决策执行，不要自行改变方案。有异议
   先写理由给我看。

5. 不要 commit、不要 push、不要新建分支。改完留在工作区，我自己审。

6. 只改本轮范围涉及的代码。不做无关重构、不重排 import、不改格式。

--- 验证要求 ---

  xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
    -only-testing:MuseTests/TypingBehaviorsTests

当前基线：TypingBehaviorsTests 19 个 / 全量 139 个测试全部通过。
**本轮必须跑全量**——上一轮只跑了相关套件，缺陷 8 改的是块类型识别，影响面覆盖
渲染与解析，只跑 TypingBehaviorsTests 不足以证明无回归。

每条缺陷都必须做双向变异验证，并把结果报给我。

  缺陷 8：正向断言——``` 围栏内的一行 `- item` 按 Enter 不注入 bullet；4 空格缩进
         代码块同理；`- - -` 和 `* * *` 按 Enter 不变成列表（它们是 .rule，见
         Parsing/MarkdownSemantics.swift:160）；`> - item` 按 Enter 能正确续行
         （这是现在的漏判，修完应该可用）。
         变异——把块类型判定改回纯正则，上述断言必须变红。
         反向变异——把块类型判定收紧到「只有顶层列表才续行」，普通嵌套列表的
         续行必须变红（否则等于把功能关掉也没人发现）。

  缺陷 14：断言多插入点时 performSmartNewline 返回 false（回退给系统），而不是
          只处理主选区并折叠其余选区。变异——去掉 selectedRanges.count == 1
          守卫，必须变红。

报告里请**逐条列出对现有测试的修改**，包括「把某条断言的输入从 X 改成 Y」这类
retarget——上一轮改了 pairDefers 里一条断言的光标位置（0 → 2）但没列出来，虽然
行为另有 16 个断言守着、结论无害，但这种改动必须可见。

不要为了让测试变绿而放宽断言。如果某条断言写不出来，停下来告诉我原因。

--- 交付 ---

改完给我：
  1. 每条缺陷改了什么、为什么这么改（一两句）
  2. 每条缺陷的双向变异验证结果（注入后测试是否变红，失败断言数）
  3. 新增/修改了哪些测试，以及它们各自能抓住什么样的错误
  4. git diff --stat
如果中途发现文档里某条描述与实际代码不符，停下来告诉我，不要自行改变方案。
````

**后续轮次的改法**：把「本轮范围」和「验证要求」里的缺陷编号替换成下一阶段，其余不动。

- ~~**第一轮**：缺陷 1、15、2~~ ✅ 完成并复审通过（2026-08-28）
- ~~**第二轮**：缺陷 16、3、4~~ ✅ 完成并复审通过（2026-08-28）
- ~~**第三轮**：缺陷 5、6、7、10、11、12~~ ✅ 完成并复审通过（2026-08-28）；缺陷 5 部分修复，见 D3
- **本轮**：缺陷 8、14（P2）
- **清理轮**：缺陷 13——把 `pendingPair` 与 `pendingAsteriskUpgrade` 合并成一套编辑计数器，顺带压缩 `insertText` 的长度（现已 274 行）。
- **最后**：缺陷 9（仅 `isEditable` 门禁与 `flags.isEmpty`）+ `## 其余已确认问题`。

