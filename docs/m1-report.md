# M1 评价报告

- 日期：2026-08-27
- 范围：v0.3 方案 §06 中 M1「骨架」的退出条件
- 结论：**通过（PASS）**，M1-1 与 M1-2 已完成

M1 的退出条件是：Xcode 工程；`NSDocument → EditorBuffer → NSTextStorage` 单一所有权；open/save/autosave；SwiftUI 外壳。

---

## 1. 交付物

| 交付物 | 位置 | 行数 | 状态 |
|---|---|---:|---|
| Xcode 工程（Xcode 26 / Swift 6，MainActor 默认隔离） | `Muse.xcodeproj` | — | ✅ |
| 共享核心框架 | `MuseKit` target（`Document/`、`Parsing/`、`Rendering/`） | — | ✅ M1-2 |
| App 入口 | `App/main.swift`、`App/AppDelegate.swift` | 62 | ✅ |
| 文档生命周期 | `Document/MuseDocument.swift` | 71 | ✅ |
| 唯一可变正文 | `Document/EditorBuffer.swift` | 14 | ✅ |
| TextKit 2 编辑面 | `Editor/EditorTextView.swift` | 55 | ✅ |
| SwiftUI ↔ AppKit 桥 | `Editor/EditorView.swift` | 65 | ✅ |
| SwiftUI 外壳 | `Editor/EditorShellView.swift` | 30 | ✅ |
| 文档往返与生命周期测试 | `MuseTests/DocumentTests.swift` | — | ✅ 8 项 |

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
| `autosaveWritesToDisk` | autosave 完成回调后磁盘内容含编辑结果 |
| `reopenRestoresContent` | 新文档从同一 URL 读取后恢复编辑内容 |
| `renderingDoesNotMarkDocumentDirty` | 只应用渲染属性不产生文档脏状态 |
| `textEditMarksDocumentDirty` | 字符编辑产生文档脏状态 |

## 3. TextKit 2 手工栈：达标

`EditorTextView.make` 显式构建 `NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer → NSTextView`，并带 `assert(textView.textLayoutManager != nil)` 防止静默退回 TextKit 1。全工程无 TextKit 1 `layoutManager` 访问。

同时关掉了所有会改写输入的自动替换（引号/破折号/文本替换/拼写纠正/链接检测/smart insert-delete），这对「渲染只写属性、不改字符」是必要前提——否则系统会在用户不知情时改动源码字符。

## 4. 一个 M1 决策的下游影响（当时未记录）

`EditorView` 用 `NSViewRepresentable` 把 `NSScrollView` + `EditorTextView` 装进 SwiftUI。这个选择本身正确（方案 §02 要求 SwiftUI 承载外壳），但有一个当时没有被记录的后果：

**SwiftUI 的宿主视图会强制整个子树 layer-backing。** 实测运行时 `textView.wantsLayer == true`，即使代码里显式设为 `false` 也无效。

这直接决定了块级视觉不能走视图级绘制钩子——`draw(_:)` / `drawBackground(in:)` 的输出会被 fragment 图层覆盖。M2 期间踩到了这个坑（见《M2 评价报告》§3）。

M1 当时无法预知这一点（M1 范围内没有块级视觉），但**这类「宿主环境约束」应当在骨架里程碑就记录下来**，因为它会约束后续所有渲染实现。v0.3 方案 §02 与 §4.8 已补入。

## 5. 补齐记录

### 5.1 autosave、reopen 与脏状态（M1-1，✅ 已解决）

M1-1 已用临时目录和 AppKit autosave 完成回调覆盖「编辑 → autosave → 磁盘」以及「同一 URL reopen」。

新增测试证明：

- autosave 真的触发；
- autosave 后 reopen 能恢复内容；
- `updateChangeCount` 的调用时机正确（启动示例文档调了 `.changeCleared`，编辑时由 `RenderCoordinator.onTextEdited` 调 `.changeDone`，但渲染属性写入被包在 undo 抑制里，需确认不会误标脏）；
- 渲染属性不会误标脏，字符编辑会标脏。

4 项测试均通过；本轮没有发现渲染误标脏缺陷。崩溃恢复的系统级人工验证仍属于 M0-3 清单范围，不由这组单元测试替代。截止本次收口，累计回归为 103 项 / 7 套件。

### 5.2 测试目标不 import 产品模块，Release 下构建失败（P1，已由 M1-2 解决）

M0 报告 §4 记录过这个取舍：「测试目标（MuseTests）直接编译 Document/Parsing/Rendering 源码（非宿主 App）……App 与测试各持一份源码副本，M1 视情况引入框架化或回归宿主。」

M1 没有处理它，现在有了具体代价：**Release 配置下测试无法构建**。

```text
MuseTests/CoordinatorPipelineTests.swift:3:18: error:
  unable to resolve Swift module dependency to a compatible module: 'Muse'
```

后果是**性能数字只能在 Debug 下测**。v0.3 方案 §4.6 里 swift-markdown 的解析成本（200KB / 64.9ms）因此只有 Debug 数字，而这个数字要用来决定「全量解析够不够、要不要做块级增量」——一个架构决策依赖着一个无法在发布配置下复现的测量。

M1-2 已按首选方案把 `Document/`、`Parsing/`、`Rendering/` 抽成 `MuseKit` framework target，App 与 MuseTests 均通过 `MuseKit` 复用同一份实现；`MuseKit` 的 Release 配置开启测试可见性，以便 `@testable import MuseKit` 的测试目标完成构建。

优先级定 P1 而非 P2，因为它阻塞的是「性能验收数据的可信度」，而性能是 v0.3 §4.6 两条指标的判据。

## 6. 评价

M1 达成了它最重要的目标：**把「唯一可变正文」这条所有权边界做成了结构性保证，而不是纪律性约定。** `EditorBuffer` 只暴露只读 `string`、`updateNSView` 空实现、序列化直读 storage——想违反这条边界需要改结构，不是一时手误就能破坏的。这是 M1 最有价值的产出。

M1 补齐了原先遗漏的 autosave/reopen 验收，并用共享框架恢复了 Release 测量链路。剩余的崩溃恢复人工观感与系统级验收属于 M0-3 手工清单。

**给后续里程碑的两条要求：**

1. 退出条件里的每一项都要有对应的测试或人工验收记录。
2. 渲染属性与字符编辑必须分别验证文档脏状态，避免 autosave 与显示状态互相污染。

---

## 7. M1 补齐任务

两项补齐任务均已完成。**全局约束见《M0 评价报告》§9.1，必须先读。**

### 7.1 任务 M1-1：autosave / reopen / 崩溃恢复的测试覆盖（✅ 已完成）

**完成结果**：`MuseDocument` 的 `autosavesInPlace` 通过临时文件路径和 completion handler 得到实际验证；新文档通过 URL 初始化并恢复内容；属性渲染与字符编辑的脏状态分别得到验证。

**新增测试**：

| 测试名 | 断言 |
|---|---|
| `autosaveWritesToDisk` | 写入临时目录 → 编辑 → 触发 autosave → 磁盘内容含编辑结果 |
| `reopenRestoresContent` | autosave 后新建 `MuseDocument` 从同一 URL 读取 → `buffer.string` 与编辑后一致 |
| `renderingDoesNotMarkDocumentDirty` | 只应用渲染属性（不改字符）→ `isDocumentEdited == false` |
| `textEditMarksDocumentDirty` | 改一个字符 → `isDocumentEdited == true` |

第 3 项是重点：渲染属性写入被包在 `disableUndoRegistration` 里，但 `RenderCoordinator.onTextEdited` 挂的是 `updateChangeCount(.changeDone)`。测试已确认**渲染不会误标脏**，文档不会因显示属性变化而进入未保存状态。

若第 3 项发现确实误标脏，那是一个真实缺陷：`textStorage(_:didProcessEditing:...)` 里的 `guard editedMask.contains(.editedCharacters), !isApplyingAttributes else { return }` 已有防护，需实测确认它是否足够。

**注意**：AppKit 的 autosave 是异步的。测试里不要靠 `sleep` 等待，用 `autosave(withImplicitCancellability:completionHandler:)` 的回调，或直接调 `save(to:ofType:for:completionHandler:)` 走确定性路径。

**验收**：4 项测试存在且通过。本任务提交时总测试数由 85 增至 **89**；随后 M2 收口
新增测试，最终回归为 **103 项 / 7 套件**；本任务未发现渲染误标脏缺陷。

### 7.2 任务 M1-2：测试目标框架化，修复 Release 构建（✅ 已完成）

**完成结果**：`MuseTests` 不再重复编译 `Document/`、`Parsing/`、`Rendering/`，改为 `@testable import MuseKit`；Release 配置下测试已成功构建并全绿。历史失败输出保留如下，作为问题起点：

```text
MuseTests/CoordinatorPipelineTests.swift:3:18: error:
  unable to resolve Swift module dependency to a compatible module: 'Muse'
```

复现：

```bash
xcodebuild test -project Muse.xcodeproj -scheme Muse \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build -configuration Release
```

**已消除的代价**：性能测试现在可以在 Release 配置下重复运行。最终 Release 数字见 §8；
M2-1/M2-4 完成 AST 语义层收口后，200KB 全量 AST 解析仍低于样式落地目标。

**已完成**（首选方案）：把 `Document/`、`Parsing/`、`Rendering/` 抽成 `MuseKit` framework target，App 与 MuseTests 都依赖它。

- App target 保留 `App/`、`Editor/`
- 需要跨模块可见的类型加 `public`（`RenderEngine`、`Token`、`SourceIndex`、`Theme`、`BlockVisual`、`MuseLayoutFragment`、`MuseLayoutFragmentProvider`、`RenderCoordinator`、`EditorBuffer`、`MarkdownSemantics`、`TokenScanner`）
- `Editor/EditorTextView.swift` 引用 `MuseLayoutFragmentProvider`，所以它必须 public
- MuseTests 改为 `@testable import MuseKit`，删掉重复编译的源码文件引用
- 注意 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 要在新 target 上一致设置，否则 nonisolated 标注的语义会变

**备选方案**（若框架化受阻）：让 MuseTests 正常 `@testable import Muse`，并解决 M0 报告 §4 记录的「Swift Testing 在 AppKit 宿主进程里跑完不退出」问题。这条路更省事但没解决重复编译。

**验收**（三项均满足）：

1. Debug 下最终 **103 项**测试全绿；
2. **Release 下测试构建成功且全绿**——这是本任务的核心目标；
3. 已在 Release 下重跑 `PerformanceTests`，并将 200KB `RenderEngine.prepare`、`applyDirty`、协调器端到端耗时填入 §8；最终全量 AST 解析为 36.665ms，低于 150ms，已在《M2 评价报告》记录「全量 AST 方案确认可行，块级增量不必做」。

## 8. Release 性能基准

命令：

```bash
xcodebuild test -project Muse.xcodeproj -scheme Muse -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build-release
```

最终 Release 构建通过，测试结果为 **103 项 / 7 套件全绿**。以下为最终全量运行输出，
`RenderEngine.prepare` 已代表 AST + SourceIndex 管线。

| 场景 | Release 实测 |
|---|---:|
| 20KB `RenderEngine.prepare`（AST + SourceIndex） | 3.565 ms |
| 200KB `RenderEngine.prepare`（AST + SourceIndex） | 36.665 ms |
| 200KB `applyDirty` | 0.318 ms |
| 200KB 协调器单键路径（编辑 → 样式落地） | 33.493 ms |
| 1MB 全管线 | 1035.931 ms |

这组数字证明 Release 测量链路已恢复；200KB 全量 AST 解析与协调器端到端均满足 v0.3
的 150ms 样式落地判据，块级增量解析暂不需要。

第 3 项不是可选的。这个任务存在的唯一理由就是拿到那个数字。
