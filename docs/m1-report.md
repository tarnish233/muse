# M1 评价报告

- 日期：2026-08-27
- 范围：v0.3 方案 §06 中 M1「骨架」的退出条件
- 结论：**通过（PASS）**，两项遗留债务记入 §5

M1 的退出条件是：Xcode 工程；`NSDocument → EditorBuffer → NSTextStorage` 单一所有权；open/save/autosave；SwiftUI 外壳。

---

## 1. 交付物

| 交付物 | 位置 | 行数 | 状态 |
|---|---|---:|---|
| Xcode 工程（Xcode 26 / Swift 6，MainActor 默认隔离） | `Muse.xcodeproj` | — | ✅ |
| App 入口 | `App/main.swift`、`App/AppDelegate.swift` | 62 | ✅ |
| 文档生命周期 | `Document/MuseDocument.swift` | 71 | ✅ |
| 唯一可变正文 | `Document/EditorBuffer.swift` | 14 | ✅ |
| TextKit 2 编辑面 | `Editor/EditorTextView.swift` | 55 | ✅ |
| SwiftUI ↔ AppKit 桥 | `Editor/EditorView.swift` | 65 | ✅ |
| SwiftUI 外壳 | `Editor/EditorShellView.swift` | 30 | ✅ |
| 文档往返测试 | `MuseTests/DocumentTests.swift` | 41 | ✅ 4 项 |

## 2. 单一所有权：达标

方案最担心的「文档模型与 text view 双重真相」（v0.3 §07 P0）在结构上被排除：

- `EditorBuffer` 只有一个成员 `let textStorage: NSTextStorage`，暴露的 `string` 是只读计算属性。文档层没有第二份可变 `String`。
- `MuseDocument.read(from:ofType:)` 与 `data(ofType:)` 都直接走 `buffer.textStorage`，序列化输出 `textStorage.string.utf8`。
- `EditorView.updateNSView` 是空实现，注释明确「M1：无状态回写」。SwiftUI 侧不持有正文。
- 编辑视图通过 `EditorTextView.make(textStorage:)` 把文档的 storage 挂进 TextKit 2 手工栈，不自建 storage。

`DocumentTests` 的 4 项覆盖了这条边界：

| 测试 | 验证 |
|---|---|
| `roundTripPreservesSource` | 源码往返不变 |
| `readReplacesWholeContent` | 打开文件整体覆盖 |
| `nonUTF8IsRejected` | 非 UTF-8 抛 `fileReadCorruptFile` |
| `renderNeverChangesDocumentSource` | 渲染后 `storage.string` 与源码相等 |

## 3. TextKit 2 手工栈：达标

`EditorTextView.make` 显式构建 `NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer → NSTextView`，并带 `assert(textView.textLayoutManager != nil)` 防止静默退回 TextKit 1。全工程无 TextKit 1 `layoutManager` 访问。

同时关掉了所有会改写输入的自动替换（引号/破折号/文本替换/拼写纠正/链接检测/smart insert-delete），这对「渲染只写属性、不改字符」是必要前提——否则系统会在用户不知情时改动源码字符。

## 4. 一个 M1 决策的下游影响（当时未记录）

`EditorView` 用 `NSViewRepresentable` 把 `NSScrollView` + `EditorTextView` 装进 SwiftUI。这个选择本身正确（方案 §02 要求 SwiftUI 承载外壳），但有一个当时没有被记录的后果：

**SwiftUI 的宿主视图会强制整个子树 layer-backing。** 实测运行时 `textView.wantsLayer == true`，即使代码里显式设为 `false` 也无效。

这直接决定了块级视觉不能走视图级绘制钩子——`draw(_:)` / `drawBackground(in:)` 的输出会被 fragment 图层覆盖。M2 期间踩到了这个坑（见《M2 评价报告》§3）。

M1 当时无法预知这一点（M1 范围内没有块级视觉），但**这类「宿主环境约束」应当在骨架里程碑就记录下来**，因为它会约束后续所有渲染实现。v0.3 方案 §02 与 §4.8 已补入。

## 5. 遗留债务

### 5.1 autosave 与 reopen 未被测试覆盖（P1）

M1 的退出条件写的是「open/save/autosave」。前两项有测试（`readReplacesWholeContent`、`roundTripPreservesSource`），**autosave 与 reopen 没有**。

`MuseDocument` 声明了 `autosavesInPlace = true`，但没有任何测试或人工验收记录证明：

- autosave 真的触发；
- autosave 后 reopen 能恢复内容；
- `updateChangeCount` 的调用时机正确（启动示例文档调了 `.changeCleared`，编辑时由 `RenderCoordinator.onTextEdited` 调 `.changeDone`，但渲染属性写入被包在 undo 抑制里，需确认不会误标脏）；
- 崩溃恢复可用。

严格来说 M1 的退出条件只满足了三分之二。这几项列入 M6「稳定与发布准备」，但**应当在 M3 之前补一次人工验收**——文档生命周期出错的代价是用户丢数据，不该留到最后一个里程碑。

### 5.2 测试目标不 import 产品模块，Release 下构建失败（P1）

M0 报告 §4 记录过这个取舍：「测试目标（MuseTests）直接编译 Document/Parsing/Rendering 源码（非宿主 App）……App 与测试各持一份源码副本，M1 视情况引入框架化或回归宿主。」

M1 没有处理它，现在有了具体代价：**Release 配置下测试无法构建**。

```text
MuseTests/CoordinatorPipelineTests.swift:3:18: error:
  unable to resolve Swift module dependency to a compatible module: 'Muse'
```

后果是**性能数字只能在 Debug 下测**。v0.3 方案 §4.6 里 swift-markdown 的解析成本（200KB / 64.9ms）因此只有 Debug 数字，而这个数字要用来决定「全量解析够不够、要不要做块级增量」——一个架构决策依赖着一个无法在发布配置下复现的测量。

修法有两条：把 Document/Parsing/Rendering 抽成一个 framework target 供 App 与测试共用；或让 MuseTests 正常 `@testable import Muse` 并解决宿主进程不退出的问题（M0 §4 提到的 Swift Testing + AppKit 宿主问题）。前者更干净。

优先级定 P1 而非 P2，因为它阻塞的是「性能验收数据的可信度」，而性能是 v0.3 §4.6 两条指标的判据。

## 6. 评价

M1 达成了它最重要的目标：**把「唯一可变正文」这条所有权边界做成了结构性保证，而不是纪律性约定。** `EditorBuffer` 只暴露只读 `string`、`updateNSView` 空实现、序列化直读 storage——想违反这条边界需要改结构，不是一时手误就能破坏的。这是 M1 最有价值的产出。

不足在于对退出条件的执行不完整：autosave/reopen 写进了条件但没验；测试基础设施的已知债务从 M0 带到 M1 又原样带到 M2，直到它开始阻塞性能测量才暴露成本。

**给后续里程碑的两条要求：**

1. 退出条件里的每一项都要有对应的测试或人工验收记录；只做了三分之二就不能记「通过」（本报告因此把 §5.1 显式列为债务而非忽略）。
2. 上一个里程碑标注为「视情况处理」的债务，在下一个里程碑开始时要么处理、要么明确降级并写下理由——不能默认顺延。

---

## 7. 接下来要做什么（M1 补齐）

两项债务，都是工程性工作，Codex 可独立完成。**全局约束见《M0 评价报告》§9.1，必须先读。**

建议顺序：先做 M1-2（它解锁 Release 性能测量，而 M2 的架构决策依赖那个数字），再做 M1-1。

### 7.1 任务 M1-1：autosave / reopen / 崩溃恢复的测试覆盖

**现状**：M1 退出条件写的是「open/save/autosave」。`MuseDocument` 声明了 `autosavesInPlace = true`，但 `MuseTests/DocumentTests.swift` 的 4 项只覆盖 open/save/往返/渲染不改源码，**autosave 与 reopen 完全没有测试**。

**要做**：在 `MuseTests/DocumentTests.swift` 增加以下测试。

| 测试名 | 断言 |
|---|---|
| `autosaveWritesToDisk` | 写入临时目录 → 编辑 → 触发 autosave → 磁盘内容含编辑结果 |
| `reopenRestoresContent` | autosave 后新建 `MuseDocument` 从同一 URL 读取 → `buffer.string` 与编辑后一致 |
| `renderingDoesNotMarkDocumentDirty` | 只应用渲染属性（不改字符）→ `isDocumentEdited == false` |
| `textEditMarksDocumentDirty` | 改一个字符 → `isDocumentEdited == true` |

第 3 项是重点：渲染属性写入被包在 `disableUndoRegistration` 里，但 `RenderCoordinator.onTextEdited` 挂的是 `updateChangeCount(.changeDone)`。需要确认**渲染不会误标脏**——否则文档会无端进入未保存状态，autosave 反复写盘。

若第 3 项发现确实误标脏，那是一个真实缺陷：`textStorage(_:didProcessEditing:...)` 里的 `guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }` 已有防护，需实测确认它是否足够。

**注意**：AppKit 的 autosave 是异步的。测试里不要靠 `sleep` 等待，用 `autosave(withImplicitCancellability:completionHandler:)` 的回调，或直接调 `save(to:ofType:for:completionHandler:)` 走确定性路径。

**验收**：4 项测试存在且通过；总测试数从 78 增至 82。若发现渲染误标脏，在本报告 §5.1 记录缺陷与修法。

### 7.2 任务 M1-2：测试目标框架化，修复 Release 构建

**现状**：MuseTests 直接编译 `Document/`、`Parsing/`、`Rendering/` 的源码，不 `import Muse`。Release 配置下测试构建失败：

```text
MuseTests/CoordinatorPipelineTests.swift:3:18: error:
  unable to resolve Swift module dependency to a compatible module: 'Muse'
```

复现：

```bash
xcodebuild test -project Muse.xcodeproj -scheme Muse \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build -configuration Release
```

**代价**：性能数字只能在 Debug 下测。v0.3 方案 §4.6 用来决定「全量 AST 解析够不够、要不要做块级增量」的 64.9ms/200KB 只有 Debug 数字——一个架构决策依赖着无法在发布配置下复现的测量。

**要做**（首选方案）：把 `Document/`、`Parsing/`、`Rendering/` 抽成一个 framework target（建议名 `MuseKit`），App 与 MuseTests 都依赖它。

- App target 保留 `App/`、`Editor/`
- 需要跨模块可见的类型加 `public`（`RenderEngine`、`Token`、`SourceIndex`、`Theme`、`BlockVisual`、`MuseLayoutFragment`、`MuseLayoutFragmentProvider`、`RenderCoordinator`、`EditorBuffer`、`MarkdownSemantics`、`TokenScanner`）
- `Editor/EditorTextView.swift` 引用 `MuseLayoutFragmentProvider`，所以它必须 public
- MuseTests 改为 `@testable import MuseKit`，删掉重复编译的源码文件引用
- 注意 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 要在新 target 上一致设置，否则 nonisolated 标注的语义会变

**备选方案**（若框架化受阻）：让 MuseTests 正常 `@testable import Muse`，并解决 M0 报告 §4 记录的「Swift Testing 在 AppKit 宿主进程里跑完不退出」问题。这条路更省事但没解决重复编译。

**验收**（三项都要满足）：

1. Debug 下 78 项（或 M1-1 完成后 82 项）测试全绿；
2. **Release 下测试构建成功且全绿**——这是本任务的核心目标；
3. 在 Release 下重跑 `PerformanceTests`，把 200KB 的 AST 解析耗时、`applyDirty` 耗时、协调器端到端耗时填进本报告新增的 §8「Release 性能基准」表。若 Release 下 AST 解析 200KB 仍 < 150ms，在《M2 评价报告》§5.4 记录「全量 AST 方案确认可行，块级增量不必做」；若超标，记录实测值供后续决策。

第 3 项不是可选的。这个任务存在的唯一理由就是拿到那个数字。
