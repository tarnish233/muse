# M5 全项目代码审查 · 缺陷清单

**审查对象**：`7920dee`（2026-08-31），**全项目静态审查**，不是某次改动的 diff。覆盖 `Document/` `Parsing/` `Rendering/` `App/` `Editor/`。

**审查方式**：多角度静态审查 + 一轮对抗式自我复核。**没有跑 AppKit 探针实测** —— 这是本工单与 `m4-code-review.md` 最大的区别，m4 的数字是跑出来的，本清单的行为结论不是。因此两级判定：

| 判定 | 含义 | 修复方该怎么对待 |
|---|---|---|
| **已确认** | 代码事实经复核成立，且从代码能推出确定的错误后果 | 可以直接动手，但仍要先写出复现断言 |
| **待确认** | 代码事实成立，但错误后果依赖 AppKit 内部行为，读代码定不了 | **先复现，再改**。复现不出来就来问，不要硬改 |

**所有行号已逐条核对**（2026-08-31 对 `7920dee` 逐行 `sed` 验证），每个引用位置都精确命中所述代码。但**行号核对 ≠ 行为核对**：位置是准的，后果判定见上表。

> **方法论（承 m4 的血泪教训）**：不要凭读代码断言行为或性能，一律先跑。本次审查自己就吃了这一课 —— 初版 16 条里，**1 条被自己的复核推翻**（见「## 不要修改」），另有 **1 条从「已确认」降级为「待确认」**（缺陷 14），还有 1 条从崩溃降级成潜在不一致（见「## 潜在不一致」）。也就是说初版有 3/16 的判定过重。你在修的过程中如果发现第 4 条，那是正常的 —— 停下来说，不要为了完成工单而将错就错。

**本文件是给修复方的工单。** 硬性约束：

1. **`## 不要修改` 一节里的内容是误报**，已被复核推翻。不要「顺手修」。
2. **`## 潜在不一致` 一节不是缺陷**，没有可复现的触发路径。它值得统一，但不要在修缺陷的轮次里顺手动 —— 它涉及九处调用点。
3. **缺陷 2 必须连带改测试。** `MuseTests/DocumentTests.swift:202` 的 `reopenedDocumentIsCleanAfterRead()` 正把缺陷 2 的错误行为断言成正确行为。只改实现会让这个测试变红，那不是回归，是这个测试本身要重写。
4. **缺陷 12 必须连带改性能语料。** `MuseTests/PerformanceTests.swift:30` 的引用块只有一行，抓不到缺陷 12。不加长语料就等于修完没有守卫。
5. **不要新增第二套 Markdown 匹配器。** `Parsing/TokenScanner.swift:7` 写着「不再维护第二套 CommonMark 匹配器」。缺陷 9/10/11 全在解析层，修法必须走 cmark AST + `SourceIndex`，**禁止加正则**。
6. **不要修改 `Muse.xcodeproj/project.pbxproj`。** 项目用 `PBXFileSystemSynchronizedRootGroup`，源码目录下的新文件自动进编译。
7. **缺陷 1（输入法）单独一轮做**，不要和别的缺陷混在一个改动里。理由见该条。
8. 动手前先读 `CLAUDE.md` 的「属性契约」与「硬约束」两节。本清单里多条缺陷的修法受那些约束限制（尤其：禁止访问 `layoutManager`、绘制层禁止从源码重新解析、渲染属性必须包在 `suppressUndo` 里）。

---

## 构建与验证基线

本机 `xcode-select` 指向 CommandLineTools，**所有命令必须前置 `DEVELOPER_DIR`**（不要 `sudo xcode-select -s`）：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 全量
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'

# 单个 suite
xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/DocumentTests
```

**当前基线（2026-08-31，`7920dee`）**：全量 **288 tests / 13 suites** 全绿。

⚠️ **单个测试的 ID 必须带括号**：`-only-testing:'MuseTests/RendererTests/renderNeverChangesCharacters()'`。漏掉括号时 `xcodebuild` 匹配 0 个测试，**却依然打印 `** TEST SUCCEEDED **`**。每次都看 `Test run with N tests` 那行确认真的跑了。

**每条缺陷的修复都必须做双向变异验证**：

- **正向**：把 bug 注入回去，确认新测试变红。测试仍绿 = 测试无效，重写。
- **反向**：把修法「做过头」（范围放大、守卫收紧到把功能关掉），确认也变红。m4 的缺陷 16 就是这样发现的 —— 原 bug 被抓，但「把命中框放大到吞掉整行」这种变异完全不被抓。

---

## 三个共因

比 15 条单独看更值得动手的是这三处。**按共因修，而不是按条目逐个打补丁。**

### 共因 A · `activeTableSelection` 在切换呈现模式时不清

`RenderCoordinator.swift:1757-1767` 的 `setPresentationMode` 不重置 `activeTableSelection`（全项目仅 472 / 880 / 1270 / 1305 四处重置）。于是「源码模式下带着一个残留的表格选区」这个状态可达，**缺陷 5 和缺陷 7 的确定性触发路径都由它提供**。

补这一处的收益大于分别去修那两条。但**不能只补这一处** —— 缺陷 5/7 各自缺的闸门是独立问题，陈旧 package 那一半与呈现模式无关。

### 共因 B · 解析层系统性不认「blockquote 作为容器前缀」

缺陷 9 和 10 是同一个根因：**都从行首开始扫、只跳空格和 tab，无视节点自己的 `range.lowerBound`**。

```swift
// MarkdownSemantics.swift:679  syntaxStart(on:)
var start = lineStarts[line]
// MarkdownSemantics.swift:690  delimiterRun
var start = line.start
```

`> - a` 和 ```` > ``` ```` 各坏一种。应该收敛成**一个尊重容器前缀的辅助函数**（以节点自己的 `lowerBound` 为下界），而不是两处各打补丁 —— `CLAUDE.md` 的「避免重复实现」一节记着，同一处几何分成两份实现的后果是「任一处坏掉被另一处补上、测试再也测不出问题」。

缺陷 11 位置相邻但根因不同（列 vs 行的校验范围），不要混着改。

### 共因 C · 「先破坏，再检查」

同一种形状出现三次，都是**破坏性写入前没有重新确认前置条件**：

| 缺陷 | 位置 | 先做的破坏 | 漏掉的检查 |
|---|---|---|---|
| 2 | `MuseDocument.swift:239` | `updateChangeCount(.changeCleared)` | 这次 read 是不是崩溃恢复 |
| 4 | `ProjectWorkspace.swift:212` | 后续 `saveSnapshot` 覆盖持久化 blob | 上一次 decode 是不是静默失败了 |
| 15 | `EditorWindowController.swift:230` | `previousDocument.close()` | `isDocumentEdited` 在异步 open 之后是否变了 |

缺陷 7 也沾这个形状（先写剪贴板，再试着删）。修的时候把「破坏性操作前重新取一次前置条件」当成统一的手法，而不是四处各写一个 if。

---

## 修复顺序

按「边界清晰程度 + 测试可写程度」排，不完全按严重度 —— 严重度最高的缺陷 1 排在最后是刻意的。

| 轮次 | 缺陷 | 理由 |
|---|---|---|
| **第一轮** | 2、3、4 | 三条数据丢失，边界清晰、互不相干，都能写确定性测试 |
| **第二轮** | 5、6、7 + 共因 A | 同一片表格代码，一起测 |
| **第三轮** | 9、10、11 + 共因 B | 同一片解析代码，纯值层最好测 |
| **第四轮** | 8、12、13 | 坐标与性能，各自独立 |
| **第五轮** | 1 | 动的是 revision 契约，必须单独一轮 |
| **待确认轮** | 14、15 | 先复现，复现不出来就来问 |

**缺陷 1 排最后不是因为它不重要** —— 它是唯一会崩溃、也是唯一会把整条渲染管线永久卡死的一条。排最后是因为：它改的是 `RenderCoordinator` 的 revision 三段式契约（`CLAUDE.md` 里那段类注释即设计契约），而 `CLAUDE.md` 明确记着**真实中文输入法矩阵的人工验收尚未回填**，所以它既动了最核心的不变式、又是最难自动验证的一条。前四轮的改动都不依赖它。

---

## P0 · 崩溃与数据丢失

### 1. 输入法组字期间的早退让陈旧 package 成为权威，可崩溃、也可永久卡死管线

**位置**：`Document/RenderCoordinator.swift:179`（累积路径）、`:248`（应用路径）

```swift
// :179  didProcessEditing 里
guard textView?.hasMarkedText() != true else { return }
// :248  applyParsed 里
guard textView?.hasMarkedText() != true else { return }     // 候选态上屏后重排
```

**现象**：`:179` 的早退同时跳过了**脏区累积**和 **`revision` 递增**。`revision` 不变，意味着一个「早于输入法插入字符」的 package 仍能通过 `applyParsed` 的 `guard rev == revision`，被当成权威结果发布。

**触发**：一次 ASCII 按键把 `revision` 推到 N 并启动 `prepare(snapshot_N)`；用户随即开始用输入法组字，于是每一次编辑都撞上 `:179` 的早退；`prepare` 恰在 marked range 清空之后完成 —— 此时因为**上屏可以让文本变短**（marked `"zhongwen"` = 8 个 UTF-16 单元 → 「中文」= 2 个），`snapshot_N` 里的区间会超出当前 `storage.length`，`setAttributes` 抛 `NSRangeException`。

**另一条路径更隐蔽**：`:248` 走丢弃分支时，既不清 `pendingDirtyRange` 也不重新排队。而 `pendingDirtyRange` 是 `CLAUDE.md` 写明的**全局闸门**（非 nil ⇒ `lastPackage` 已过期）。它一旦永久非 nil，marker 显隐、模式切换、图片刷新、以及**所有表格结构操作**全部永久失效 —— 不崩，但编辑器悄悄变成半残。

**建议改法**：早退只应该跳过「应用属性」，不应该跳过「记账」。`:179` 处即使 marked 也要累积脏区并递增 `revision`（`CLAUDE.md` 记着协调器已经分开维护「目标模式」和 `appliedPresentationMode`，这里要的是同一个思路：延后的是*生效*，不是*记录*）。`:248` 的丢弃分支必须保留 `pendingDirtyRange` 并重新 `scheduleParse`，让它在上屏后能自愈。另外在 `setAttributes` 之前对区间做一次 `storage.length` 夹取作为兜底 —— 但**兜底不能代替修根因**，夹取只是把崩溃换成静默错位。

**为什么单独一轮**：这条动的是 revision 三段式契约本身。而且 `CLAUDE.md` 记着真实输入法矩阵的人工验收尚未回填 —— 自动测试只能构造 `hasMarkedText()` 的桩，真机行为要人工过一遍。

**验证**：
- 正向断言 —— 构造「ASCII 按键 → 组字期间多次编辑 → 上屏使文本变短 → 陈旧 package 回来」的序列，断言不抛异常且最终属性与全文重算一致。
- 正向断言（第二条路径）—— 走 `:248` 丢弃分支后，断言 `pendingDirtyRange` 最终能回到 nil，且此后表格操作可用。
- 变异 —— 把 `revision` 递增改回早退之前，第一条断言必须变红；把 `:248` 的重新排队删掉，第二条必须变红。

---

### 2. `makeWindowControllers` 无条件清脏标记，擦掉崩溃恢复

**位置**：`Document/MuseDocument.swift:239`（另有一处同样的调用在 `:232`）

```swift
public override func makeWindowControllers() {
    guard let factory = Self.windowControllerFactory else {
        updateChangeCount(.changeCleared)          // :232
        return
    }
    addWindowController(factory(self))
    // 启动时填入的示例不算未保存修改。
    updateChangeCount(.changeCleared)              // :239
}
```

**现象**：`:238` 的注释说明了真实意图 —— 「启动时填入的示例不算未保存修改」。但这个清除是**无条件**的，因此也会擦掉 AppKit 在「从自动保存内容恢复文档」时设置的脏标记。

**触发**：`note.md` 有未保存修改时 App 崩溃；重启后 AppKit 读入恢复出来的文本并把文档标记为已编辑，紧接着这一行把 change count 归零 —— 于是 ⌘W 既不提示、也不做最后一次自动保存，恢复内容就没了。全项目搜不到 `.changeReadOtherContents`。

**建议改法**：把清除**限定到它真正要服务的场景**（全新未命名文档 + 示例内容），而不是所有 read。可判据：`fileURL == nil && autosavedContentsFileURL == nil`。`:232` 那处（无 UI 宿主）同样要判 —— 序列化/性能测试走的是这条，但它也不该擦恢复态。

**⚠️ 必须连带改测试**：`MuseTests/DocumentTests.swift:202` 的 `reopenedDocumentIsCleanAfterRead()` 正把当前行为断言成正确行为。改完这个测试会变红 —— **那不是回归，是这个测试本身要重写**：把它拆成两个，「全新文档 + 示例内容 → clean」保留，「从自动保存内容恢复 → dirty」新增。

**验证**：
- 正向断言 —— 模拟恢复读入（设置 `autosavedContentsFileURL` 后 read），断言 `isDocumentEdited == true`。
- 反向变异 —— 把判据收紧成「永不清除」，`reopenedDocumentIsCleanAfterRead()` 重写后的「示例内容」那一半必须变红（否则等于把原有意图丢了也没人发现）。

---

### 3. 粘贴与拖拽不做行尾归一，把坏字节写进磁盘

**位置**：`Editor/EditorTextView.swift:1537`

```swift
override func paste(_ sender: Any?) {
    if tablePasteHandler?(NSPasteboard.general) == true { return }
    super.paste(sender)                                   // :1537
}
```

**现象**：`paste()` 和拖拽都直接落到 `super`，不做任何行尾归一，于是 CR / CRLF / U+2028 原样进 storage。这**违反 `CLAUDE.md` 写明的不变式**：「换行符归一是无条件的（存储只许有 LF）」。

**触发**：打开一个 CRLF 文件（`lineEnding == .crlf`），从 Windows 应用或浏览器拷一段文本粘进来，保存 —— `data(ofType:)` 会对**已经是 `\r\n`** 的内容再跑一次 `replacingOccurrences(of: "\n", with: "\r\n", .literal)`，写出 `\r\r\n`。另外，粘进来的 U+2028 正是 `⌃Return` 覆写专门要防的那个字符（cmark 不认它是换行，而文档层原样写盘），它从 ⌘V 大摇大摆走了进来。

**建议改法**：**不要在 `paste` 和拖拽两处各写一遍归一** —— `CLAUDE.md` 的「避免重复实现」正是在说这个。AppKit 把粘贴和拖放都汇聚到 `readSelection(from:type:)`，覆写这一个入口即可同时覆盖两条路径。归一后要走 `shouldChangeText` / `insertText` 路径写入，不要绕过 delegate 否决权。

字符串操作**必须用 `.literal`**：`CLAUDE.md` 记着 `"\r\n"` 在 Swift 里是单个 `Character`，默认语义下 `contains("\r")` 对 CRLF 返回 **false**。归一顺序也要注意：先 CRLF → LF，再孤立 CR → LF，再 U+2028/U+2029 → LF。

**验证**：
- 正向断言 —— 分别粘贴含 `\r\n`、孤立 `\r`、U+2028 的文本，断言 storage 里只有 `\n`；再对 `lineEnding == .crlf` 的文档走一次完整存盘，断言磁盘字节里没有 `\r\r\n`。
- 断言拖放路径 —— 同样的三种输入经拖放进入，结论一致（这一条专门守「只修了 paste、忘了 drop」）。
- 变异 —— 把归一里的 `.literal` 去掉，CRLF 那条断言必须变红。

---

### 4. 项目列表解码静默失败后，下一次保存把还能恢复的数据覆盖掉

**位置**：`Editor/Workspace/ProjectWorkspace.swift:212`

```swift
private func restoreProjects() {
    guard let data = projectStore.load(),
          let stored = try? JSONDecoder().decode([StoredProject].self, from: data)   // :212
    else { return }
```

**现象**：`try?` 把解码错误吞掉，`restoreProjects()` 直接早退，`projects` 停在初始的空数组，**且不设 `presentedError`**。侧栏于是显示空状态 —— 与「本来就没存过项目」完全无法区分。用户重新添加文件夹，`addProject` 调 `saveSnapshot`，**那份还能恢复的原始 blob 就被覆盖了**。

对比同一个方法里的其他失败路径：`:225`、`:242`、`:263` 全都 `restorationErrors.append(error)`，最后 `:266` 统一 `report(...)`。只有解码这一处是静默的。

**建议改法**：区分**三种**状态，不要只区分两种：

| 状态 | 判据 | 行为 |
|---|---|---|
| 从没存过 | `projectStore.load()` 返回 nil | 静默返回（现有行为正确） |
| 存过、解码失败 | `load()` 有数据但 decode 抛错 | 走 `restorationErrors` + `report(...)`，**并且置一个「本次未成功恢复」标志，阻止后续 `saveSnapshot` 覆盖**，直到用户确认 |
| 存过、解码成功 | —— | 现有流程 |

只加 `report(...)` 是不够的 —— 报了错但照样让 `addProject` 覆盖，数据仍然会丢。**阻止覆盖是这条的主体**。

**验证**：
- 正向断言 —— 往 store 里塞一段无法解码的数据，调 `restoreProjects()`，断言 ① 有 error 被 report ② 随后调 `addProject` 后原始 blob **仍在** store 里。
- 断言不误伤 —— `load()` 返回 nil 时不 report、不阻止保存。
- 变异 —— 把阻止覆盖的标志去掉，第一条的 ② 必须变红（这一条专门守「只报错、没防覆盖」这种半修）。

---

## P1 · 静默改坏用户文本

**本节三条加共因 A 一起修。** 先补共因 A，再补各自的闸门 —— 顺序反了会让你以为闸门没生效。

### 共因 A 的确切位置

```swift
// RenderCoordinator.swift:1757
public func setPresentationMode(_ mode: RenderEngine.PresentationMode) {
    if presentationMode != mode {
        presentationMode = mode
        revealCache.removeAll(keepingCapacity: true)
        lastReconcileWriteCount = 0
        if mode != .rendered {
            pendingTableNavigations.removeAll(keepingCapacity: true)   // 清了这个
        }                                                              // 漏了 activeTableSelection
    }
    applyPresentationModeIfPossible()
}
```

离开 `.rendered` 时清了 `pendingTableNavigations`，**紧挨着的 `activeTableSelection` 没清**。全项目仅 `:472` `:880` `:1270` `:1305` 四处重置，都不在模式切换路径上。补在 `if mode != .rendered` 那个分支里即可。

---

### 5. `pasteTableSelection` 两个闸门都没有，⌘V 会覆写无关行

**位置**：`Document/RenderCoordinator.swift:769`

```swift
public func pasteTableSelection(from pasteboard: NSPasteboard) -> Bool {
    guard let source = pasteboard.string(forType: ...) ?? pasteboard.string(forType: .string),
          let pasted = parsedClipboardTable(source),
          !pasted.rows.isEmpty,
          let package = lastPackage,          // ← 没有 pendingDirtyRange == nil
          let storage = textStorage,          // ← 没有 presentationMode == .rendered
          let textView,
          let target = tablePasteTarget(package: package)
    else { return false }
```

对照**其他所有**表格结构操作都带的那道闸门（`:538-539`）：

```swift
guard presentationMode == .rendered,
      pendingDirtyRange == nil,
```

**两条独立的触发**：

1. **源码模式（确定性，不需要竞态）**：借共因 A 残留的 `activeTableSelection`，在源码模式下按 ⌘V —— 直接把那张表重写并重排版。
2. **陈旧 package（需要撞上后台解析窗口）**：⌘V 落在后台 `prepare` 未回来的窗口里，于是按陈旧 package 算出的区间做序列化写入。而 `tableSourceRange` 唯一的检查是拿**当前**字符串量的 —— 一个「陈旧但仍在界内」的偏移能通过检查，`replaceCharacters` 就覆写了无关行。

**建议改法**：补齐 `:538-539` 那两个条件。**不要只补 `presentationMode`** —— 那只挡住第 1 条触发，第 2 条与呈现模式无关。

**验证**：
- 断言源码模式下 ⌘V 不改正文（且函数返回 false，让 `super.paste` 接手）。
- 断言 `pendingDirtyRange != nil` 时 ⌘V 不改正文。
- 变异 —— 分别去掉两个条件，对应断言各自变红（这一条专门守「只补了一个闸门」）。

---

### 6. 拖拽行可以拖到表头位置，把表头顶掉

**位置**：`Document/RenderCoordinator.swift:1099`

```swift
guard source >= 0, source < table.rows.count,
      destination >= 0, destination < table.rows.count      // ← 允许 destination == 0
else { return false }
var rows = tableRows(table, package: package, storage: storage)
guard rows.count == table.rows.count else { return false }
let moved = rows.remove(at: source)                          // :1099
rows.insert(moved, at: destination)
```

**现象**：`reorderTable` 和「上方插入行」把 `rows[0]`（表头）当普通行处理，只守了 `0 <= source/destination < rows.count`。

**触发**：把数据行 3 往上拖，直到落点指示器压在表头上 —— `rows.remove(at: 3)`、`rows.insert(moved, at: 0)`，而 `serializeTable` 永远把 `rows[0]` 当表头输出、后面紧跟分隔行。结果：被拖的那行变成了表头，真正的表头被降级成正文行。

**佐证**：`pasteTableSelection` 在 `:794` 有 `if target.row == 0 {` 的特殊处理 —— 说明第 0 行的特殊性在别处是被承认的，只有这里漏了。

**建议改法**：`destination` 的下界收成 1，`source` 同样（表头不可被拖动）。注意 `insert(at:)` 的上界语义 —— 拖到最后要允许 `destination == rows.count - 1`。「上方插入行」也走这条路径，同样要挡住「在表头上方插入」。

**验证**：
- 正向断言 —— 拖行到 destination 0 被拒（返回 false），表头不变。
- 断言不误伤 —— 拖到第 1 行（表头正下方）仍然可用，拖到末行可用。
- 反向变异 —— 把下界收成 2，「拖到第 1 行」必须变红（否则等于顺手把合法操作也禁掉了）。

---

### 7. ⌘X 在源码模式下拷走表格却不删除

**位置**：`Document/RenderCoordinator.swift:745`

```swift
public func copyTableSelection(to pasteboard: NSPasteboard, cut: Bool = false) -> Bool {
    guard let active = activeTableSelection,      // ← 两个闸门都没有
          let package = lastPackage,
          ...
    pasteboard.clearContents()                    // :759  先写剪贴板
    pasteboard.setString(markdown, forType: .string)
    pasteboard.setString(markdown, forType: ...("com.muse.table"))
    if cut {
        return performTableAction(tableID: active.tableID, action: .delete(bounds))   // :763  后删除
    }
    return true
}
```

**现象**：两个闸门都没有，而且**剪贴板写入发生在它配套的删除之前**。

**触发**：源码模式下带着残留的表格选区按 ⌘X —— `:759-761` 先把表格写进剪贴板；`:763` 的 `performTableAction` 撞上自己的 `guard presentationMode == .rendered, pendingDirtyRange == nil`（`:538-539`）直接返回 false；于是 `copyTableSelection` 返回 false，`EditorTextView.cut`（`:1530-1533`）落到 `super.cut`。**净结果：剪贴板里是一份正确的表格，正文里那张表没被删。**

注意这条**不丢数据**（表还在、剪贴板也对），但用户会以为剪走了。

**建议改法**：补齐两个闸门（同缺陷 5），并且**把剪贴板写入移到删除成功之后** —— `cut` 分支应该先试删除，成功了再写剪贴板。共因 C 的手法：破坏性操作（这里是「宣称已剪切」）之前重新确认前置条件。

**验证**：
- 正向断言 —— 源码模式下 ⌘X：剪贴板**未被改动**，正文未被改动，返回 false。
- 断言渲染模式下 ⌘X 仍然正常（剪贴板有内容 + 正文被删）。
- 变异 —— 把剪贴板写入移回删除之前，第一条断言必须变红。

---

### 8. `imageDestination` 用错坐标系，`NSNotFound` 被静默夹成末字符，点击彻底失灵

**位置**：`Editor/EditorTextView.swift:1613`

```swift
func imageDestination(at point: CGPoint) -> String? {
    guard let storage = textStorage, storage.length > 0 else { return nil }
    let index = min(max(0, characterIndex(for: point)), storage.length - 1)   // :1613
    return storage.attribute(.museImageDestination, at: index, effectiveRange: nil) as? String
}
```

**两个错叠在一起**：

1. `point` 是**视图坐标**，而 `characterIndex(for:)` 是 `NSTextInputClient` 的方法，收**屏幕坐标**。
2. 命中失败时它返回 `NSNotFound`（一个极大值），`min(..., storage.length - 1)` 把这个失败**静默夹成了「文档最后一个字符」**。

**触发**：任何**以图片结尾**的文档（末字符带 `.museImageDestination`）—— 每一次普通左键点击都会解析出那张图片，然后 `mouseDown` 在图片分支里 `return`，**不调用 `super.mouseDown`**：

```swift
if Self.isCheckboxToggleCandidate(event),
   hasMarkedText() == false,
   let destination = imageDestination(at: point)
{
    window?.makeFirstResponder(self)
    showImagePreview(destination: destination, at: point)
    return                      // ← 吞掉 super.mouseDown
}
super.mouseDown(with: event)
```

于是光标再也无法用点击放置，拖选也完全起不来 —— 编辑器基本不可用。

**建议改法**：两个错都要修，**只修一个不够**。

- 坐标：走 TextKit 2 的命中路径（`textLayoutManager` + `NSTextLayoutFragment`）。**禁止访问 `layoutManager` / `NSLayoutManager`** —— `CLAUDE.md` 记着那会不可逆地进入 TextKit 1 兼容模式。优先复用文件里 checkbox 命中已经在用的那套视图坐标 → 字符索引路径，不要新写一套（同「避免重复实现」）。
- 失败语义：`NSNotFound` **必须返回 nil**，不许夹取。夹取是这条能扩散成「点击全失灵」的直接原因。

**验证**：
- 正向断言 —— 以图片结尾的文档里，点击**正文区域**返回 nil（而不是那张图片的 destination）；点击图片本身返回正确 destination。
- 断言 `super.mouseDown` 被调用 —— 普通点击后光标位置确实变了（这一条守的是后果，不是中间值）。
- 变异 —— 把 `NSNotFound → nil` 换回夹取，第一条断言必须变红。

---

## P2 · 解析层：blockquote 容器前缀（共因 B）

**缺陷 9 和 10 一起修，用同一个辅助函数。** 缺陷 11 位置相邻但根因不同，不要混着改。

**修法依据就在同一个文件里** —— `appendThematicBreak`（`:672`）已经写对了：

```swift
let start = max(lineStarts[line], range.lowerBound)      // :672  ← 正确：以节点自己的下界兜底
let end = min(lines[line].end, max(start, range.upperBound))
```

而它下面六行的 `syntaxStart` 完全不看 `range.lowerBound`。**把 `:672` 这个写法提成共用辅助函数**，别再写第三种。

### 9. 引用块里的围栏代码块被整块丢弃，且行提示与 token 流互相矛盾

**位置**：`Parsing/MarkdownSemantics.swift:690`

```swift
private func delimiterRun(on line: TokenScanner.Line) -> Range<Int>? {
    var start = line.start                                          // :690
    while start < line.end, bytes[start] == 0x20 || bytes[start] == 0x09 {
        start += 1                                                  // 只跳空格和 tab
    }
    guard start < line.end, bytes[start] == 0x60 || bytes[start] == 0x7E else { return nil }
```

**触发**：源码 ````"> ```\n> c\n> ```\n"```` —— `bytes[0] == 0x3E`（`>`）既不是 0x60（`` ` ``）也不是 0x7E（`~`），于是 `delimiterRun` 返回 nil，`appendCodeBlock` 在 `:640` 的 `guard let opening = ... else { return }` 把**整个块丢掉**：没有等宽字体、没有围栏底色、没有闭合标记折叠。

**更糟的是状态不一致**：`:638` 的 `markAllLines` **已经**把第 0…2 行放进了 `fenceLines`。于是行提示说「这三行是围栏」，token 流里却没有这个块 —— 两个数据源互相矛盾，后续任何依赖其中之一的逻辑都可能走岔。

**建议改法**：`delimiterRun` 的扫描下界取节点自己的 `range.lowerBound`（照 `:672`），而不是 `line.start`。顺带确认 `isClosingFence`（`:702-710`）也走同一个下界 —— 它调的是同一个 `delimiterRun`，改对了自动跟上。

### 10. 引用块里的列表标记范围吞掉引用标记

**位置**：`Parsing/MarkdownSemantics.swift:679`

```swift
private func syntaxStart(on line: Int) -> Int {
    var start = lineStarts[line]                                    // :679
    while start < lines[line].end, bytes[start] == 0x20 || bytes[start] == 0x09 {
        start += 1
    }
    return start
}
```

**触发**：源码 `"> - a\n"` —— `contentStart` 是 4，而 `syntaxStart(on: 0)` 返回 **0**，因为 `bytes[0] == '>'` 既不是空格也不是 tab。于是 marker 范围是 `0..<4`（`"> - "`）而不是 `2..<4`。

**后果有两层**：隐藏列表标记时**连引用的 `"> "` 一起折叠**；而且 `.museListMarkerLocation` / `.museListMarkerLength` 通过 `ListMarkerGeometry` **同时**喂给标记绘制和点击命中（`CLAUDE.md` 明确记着这两者共用同一个几何函数），所以画出来的圆点和它的命中框**都**落在引用标记上。

**建议改法**：同缺陷 9，取节点 `range.lowerBound` 作为下界。标题（ATX）走的也是 `syntaxStart`，`"> # h"` 是同一个 bug 的另一种表现，一并会修好。

### 11. `byteOffset` 拿整篇字节数校验列号，列溢出会串到后面几行

**位置**：`Parsing/MarkdownSemantics.swift:900`

```swift
let line = location.line - 1
guard line >= 0, line < lineStarts.count else { return nil }        // 校验了行
let offset = lineStarts[line] + max(0, location.column - 1)         // :900
guard offset >= 0, offset <= byteCount else { return nil }          // 只校验了整篇字节数
```

**行校验得很干净，列完全没校验** —— 列号只要不让 offset 超出**整篇**长度就通过，于是一个溢出自己那一行的列号会安静地指到后面几行的字节上。

**触发**：源码 `"- x\\\n  **y**\n"`（列表项里用反斜杠硬换行，`lineStarts = [0, 5, 13]`）—— cmark 报 Strong 在 L1:C6..<L1:C11，但第 1 行只有 4 个字节。于是 `byteRange(strong)` 算出 `5..<10` = `"  **y"`，而正确答案是 `7..<12`。`appendInline` 随后产出 `openMarker` = 那两个缩进空格、`closeMarker` = `"*y"`、`content` = `"*"` —— **把缩进当成 `**` 折叠掉、把一个字面 `*` 加粗、并且把 token 记到了错误的行上**。

**建议改法**：加一道以**该行自己的 end** 为界的夹取（`lines[line].end`），越界返回 nil 而不是夹取到行尾 —— 参考 `:899` 已有的 `guard ... else { return nil }` 风格，失败就 nil，别夹。

### 共因 B 的验证

- 正向断言（纯值层，最好测）—— 对 `"> - a\n"`、`"> # h\n"`、````"> ```\n> c\n> ```\n"````、`"- x\\\n  **y**\n"` 四个输入分别断言产出的 marker / block 范围精确值。
- 断言状态一致 —— 引用里的围栏：`fenceLines` 与 token 流对同一批行的判断必须一致（这一条专门守缺陷 9 的第二层）。
- 断言不误伤 —— 顶层的 `- a`、`# h`、`` ``` `` 围栏、普通嵌套列表，范围与修改前完全一致。
- **禁止加正则**（硬性约束 5）。修法必须走 AST 的 `range.lowerBound`。
- 变异 —— 把下界改回 `lineStarts[line]` / `line.start`，前两组断言必须变红；反向变异：把下界收紧到「总是用 `range.lowerBound`、不再跳空格」，「不误伤」那组里带缩进的用例必须变红。

---

## P2 · 性能

### 12. 引用块脏区无上界，一次回车重排整个引用

**位置**：`Rendering/RenderEngine.swift:327`

```swift
let oldQuotes = quoteLines(of: previousPackage)
let newQuotes = quoteLines(of: package)
if oldQuotes != newQuotes {                                         // :327
    let quoteRanges = (
        contiguousRanges(oldQuotes) + contiguousRanges(newQuotes)
    ).compactMap { clamped($0, to: validLines) }
    extendConnectedRange(&dirtyLines, candidates: quoteRanges)       // 整段并入，之后无 clamp
}
```

**`:323-324` 的注释说明了本意**：「引用拓扑未变化时普通正文编辑保持局部」。`if oldQuotes != newQuotes` 这道闸门就是为了保持局部的 —— 问题是它挡不住。

**现象**：引用 token 是**逐行**产出的（`MarkdownSemantics.swift:596` 的 `for line in lineSpan(of: range)`），所以 `quoteLineSet` 装着每一个引用的每一行；`contiguousRanges` 把一个长引用塌成一整段，`extendConnectedRange` 再整段并进 `dirtyLines`，**后面没有任何 clamp**。

**触发**：任何**改变行数**的编辑（回车、退格）——行号整体位移，于是新旧集合**必然**不同，闸门失效，整个引用每次按键全量重排，对着 16 ms 的预算。

**两点要说清**（初版把这条说过重了）：
- 引用内**普通按键**不改行数，集合相同，闸门是有效的 —— 这条**只在改变行数时**触发。
- 那两次 sort 只在这个分支里跑，不是每次输入都跑。

**⚠️ 必须连带改语料**（硬性约束 4）：`MuseTests/PerformanceTests.swift:30` 的引用块只有一行：

```
> 引用块内容，包含 **加粗** 与中文。
```

单行引用的「整段」就是它自己，抓不到这条。**不加长语料就等于修完没有守卫。**

**建议改法**：闸门的判据要对「纯位移」免疫 —— 比较前先按本次编辑造成的行数差把旧索引重基（编辑点之后的行整体加/减 delta），这样纯位移不再被判成拓扑变化。真正的拓扑变化（引用的起止行、嵌套层级变了）仍然要触发扩张。**不要用「取新旧交集」之类的省事写法** —— CommonMark 的 lazy continuation 只能由 AST 判定，`:323` 的注释就是在说这件事。

**验证**：
- 先把语料里的引用块加长到 ≥ 40 行，再做以下断言。
- 正向断言 —— 长引用**中间**按回车，脏行范围不超过「编辑行 ± 常数」，**不随引用长度增长**。
- 断言不误伤 —— 真正改变引用拓扑的编辑（在引用中间插一个空行把它拆成两段）仍然全量扩张。
- 变异 —— 把重基逻辑去掉，第一条断言必须变红；反向变异：把扩张彻底关掉，第二条必须变红。
- 门槛以 **Release** 为准（`CLAUDE.md`：Debug 数字只用于发现明显退化）。

### 13. 远端图片逐字节下载并在主 actor 上同步解码，点一下就卡住编辑器

**位置**：`Editor/ImagePreview.swift:105`

```swift
for try await byte in bytes {                                       // :105
    guard data.count < Self.maxRemoteBytes else {
        return .failure("图片超过 20 MB，无法预览")
    }
    data.append(byte)
}
guard let image = downsampledImage(data: data) else { ... }
```

**现象**：target 用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 构建，而 `ImagePreviewController` 是 `NSViewController` 子类、没有任何 `nonisolated` 标注 —— 所以 `static func load` **是主 actor 隔离的**。一个 20 MB 文件意味着最多约 **2000 万次**主 actor 的获取/释放，紧接着还有一次同步的 `CGImageSourceCreateThumbnailAtIndex`（`:120-127`）。点一下远端图片，编辑器就在转圈里冻住。

**注意这个循环有它的道理**，不要直接换成 `data(from:)`：`:106-108` 的 `guard` 是在**流式**执行 20 MB 上限，因为 `:96-97` 的 `expectedContentLength` 可能是 -1（未知），那时只能边下边数。

**建议改法**：主体是**把 `load` 和 `downsampledImage` 标成 `nonisolated`**，让下载与解码离开主 actor —— 这一步就消除了冻结。流式上限保留。逐字节 append 可以顺带改成分块累积，但那是次要优化，`nonisolated` 才是根治。

**验证**：
- 断言 `load` 不在主 actor 上执行（或等价地：下载期间主 actor 仍可响应）。
- 断言 20 MB 上限在 `expectedContentLength == -1` 时仍然生效（这一条守「改成 `data(from:)` 把上限丢了」）。
- 变异 —— 去掉 `nonisolated`，第一条断言必须变红。

---

## P3 · 待确认（先复现，再改）

**这两条的代码事实成立，但错误后果依赖 AppKit 内部行为，读代码定不了。复现不出来就来问，不要硬改。**

### 14. 块视觉调色板在初始化时写死亮色，只有「变化」时才刷新

**位置**：`Rendering/Theme.swift:451`，唯一生产刷新点在 `Editor/EditorTextView.swift:428`

```swift
// Theme.swift:450-455
private init() {
    guard let appearance = NSAppearance(named: .aqua) else {        // :451  写死亮色
        fatalError("The system Aqua appearance is unavailable.")
    }
    current = Self.snapshot(for: appearance)
}
```

**已核实的代码事实**（2026-08-31 亲手查过）：

- `BlockVisualPalette.shared` 初始化时确实写死 `.aqua`（亮色）。
- 全项目 `update(for:)` 的**生产**调用点只有一个：`EditorTextView.swift:428`，在 `viewDidChangeEffectiveAppearance()` 里 —— 是个**变化**回调。其余五处调用都在 `MuseTests/RendererTests.swift`。
- `AppPreferences.applyAppearance()` 在 `AppDelegate.applicationWillFinishLaunching`（`AppDelegate.swift:9`）里就设了 `NSApp.appearance`（`AppPreferences.swift:35`），**早于任何窗口和 text view 存在**。
- 因此**没有任何东西在 view 诞生时按真实外观建立调色板**。

**为什么是「待确认」而不是「已确认」**：初版断言的后果是「引用底色、围栏底色、边框、表头/斑马纹、两种 checkbox 颜色整个会话都是亮色画在暗色上」。**但这个后果每次在深色模式下开 App 都会看见**，而它没有被观察到 —— 说明 AppKit 实际上会在 view 首次进入窗口层级时触发那个变化回调。所以：**代码脆弱性是真的（少一个诞生时的建立点），「整个会话都坏」这个后果大概不是真的。**

**复现方法**：系统切到深色模式，启动 App，看引用块底色。是暗色 → 后果不成立，这条降级成「加一个诞生时的刷新点」的健壮性改动。是亮色 → 后果成立，按已确认处理。

**建议改法**（无论复现结果如何都值得做）：在 text view 装配完成时**主动调一次** `BlockVisualPalette.shared.update(for: effectiveAppearance)`，不要只依赖变化回调。注意 `CLAUDE.md` 的硬约束：**颜色不能在 fragment 内直接取动态 `NSColor.cgColor`**（绘制回调不保证 `NSAppearance.current` 正确，且 fragment 会被缓存复用），所以只能走这个快照，不能在绘制处临时解析。

### 15. `adopt()` 用异步 open 之前的判断去关旧文档

**位置**：`App/EditorWindowController.swift:230`

```swift
if DocumentOpenStateMachine.shouldClosePreviousDocument(
    isSameDocument: previousDocument === document,
    remainingWindowControllerCount: previousDocument.windowControllers.count
) {
    previousDocument.close()                                        // :230
}
```

**已核实的代码事实**：`shouldClosePreviousDocument` 只看「是否同一文档」和「剩余 window controller 数量」两个入参，**整条路径上没有任何 `isDocumentEdited` 重新检查**。

**推断的后果**：异步加载期间窗口仍可交互、且仍显示旧文档 A，此时敲进 A 的按键会走到 `updateChangeCount(.changeDone)`，随后被 `:230` 的 `close()` 丢弃。

**为什么是「待确认」**：丢失窗口只有「open 完成回调」那么长（本地很短，网络卷上可能几秒），而且 `autosavesInPlace = true` 可能先把改动刷掉 —— 这两点让后果无法从代码断定。另外初版说的「不弹保存提示」不准确：已保存过的文档 `canClose` 本来就不弹。

**复现方法**：在网络卷（或人为注入延迟）上打开文档，加载期间往旧文档里敲字，看关闭后改动是否还在。

**建议改法**：`close()` 之前重新取一次 `isDocumentEdited`（共因 C 的统一手法）。

---

## 不要修改（已被复核推翻的误报）

### ✗ 「复选框命中扫描会与绘制分叉，导致光标骗人」

初版把 `Rendering/BlockLayoutFragment.swift:626` 列为正确性缺陷，说法是「命中扫描认 `[x]` 的方式与绘制分叉，光标显示可点击但点了没反应」。**两半都是错的：**

- **光标骗人这半被代码否定**：`.pointingHand` 的 cursor rect 与 toggle 用的是**同一个** `taskCheckboxHitTarget()`（`Editor/EditorTextView.swift:488-490`），所以扫描失配会让光标和 toggle **一起**消失，不存在「光标说能点、实际不能点」。文件 `:465-466` 的注释是准确的。
- **分叉的标记根本不存在**：命中扫描是「一次扫描 + 一次回退」（`:626-630`），回退那次 `marker.range(of: "[x]", options: [.caseInsensitive], ...)`（`:628`）**已经覆盖 `[X]`**；`[  ]`（两空格）和括号内带 tab 在 cmark-gfm 的 tasklist 扩展里**根本不算 task**，`guard case .task = resolved.glyph` 在扫描之前就返回 nil，而且 `:630` 还有一道 `taskRange.length == 3` 兜底；正文里的 `[x]` 也匹配不到，因为搜索被 `range: sourceMarkerRange` 限死，其上界就是段落起点。

**剩下的只是一个规范问题**：绘制层技术上确实对源码做了一次匹配，与 `CLAUDE.md` 第 82 行「绘制层禁止从源码重新解析」有张力。**但没有任何可复现的行为分叉，不要当正确性缺陷修。** 如果要动，那是一次独立的规范性重构，需要单独立项。

---

## 潜在不一致（不是缺陷，不要在修缺陷的轮次里顺手动）

### `token.line` 一半夹取、一半裸下标

`RenderEngine.Package.init` 在 `RenderEngine.swift:70` 防御性地夹取了 `token.line`：

```swift
let startLine = min(max(token.line, 0), max(0, lineStarts.count - 1))
```

而九处调用点拿同一个值**裸下标**：`RenderEngine.swift:849` `:860` `:864` `:924` `:938` `:1063` `:1101` 用的是 `package.lineStarts[token.line]`，`:968` 用的是 `package.lineStarts[line]`（局部变量，同样未经夹取），外加 `RenderCoordinator.swift:1701` 的 `package.lineStarts[token.line]`。

**没有可达的触发路径**（初版说它会崩，是过重的判定）：`sourceLine(of:)` 在 `MarkdownSemantics.swift:825` 有 `guard line >= 0, line < lines.count else { return nil }`，`byteOffset` 在 `:899` 有同形状的 guard，`lineIndex` / `lineSpan` 则用 `min(low, lines.count - 1)` 夹取。所以两种写法只是**对「这个下标可不可信」的判断相反**，不会越界。

**值得往一个方向统一** —— 要么信任它、去掉 `Package.init` 的夹取，要么不信任它、九处都走安全访问。但这是一次涉及九处调用点的独立改动，**不要混进任何一轮缺陷修复**。

---

## 附录 · 派活用的 prompt

下面这段可直接交给编码 agent（Codex 等）。**每轮只改「本轮范围」那一段**，一轮一审。

````text
任务：修复 Muse（macOS / Swift 6 / AppKit TextKit 2 的即时渲染 Markdown 编辑器）
在一次全项目代码审查中发现的缺陷。

仓库：/Users/coma_white55/workspace/muse   分支：main（工作区干净）

第一步：完整读 docs/m5-code-review.md。那是本次任务的权威工单，包含 15 条缺陷，
每条都有位置、代码片段、现象、触发条件、建议改法和验证要求。所有行号已对
7920dee 逐行核对过。不要凭这段 prompt 的概述动手，以文档为准。

第二步：读 CLAUDE.md 的「属性契约」与「硬约束」两节。本清单多条缺陷的修法受
那些约束限制，违反了会引入不可见的回归。

--- 本轮范围 ---

本轮做第一轮：三条数据丢失。边界清晰、互不相干、都能写确定性测试。

  缺陷 2  Document/MuseDocument.swift:239              无条件清脏标记，擦掉崩溃恢复
  缺陷 3  Editor/EditorTextView.swift:1537             粘贴/拖拽不做行尾归一，写坏磁盘
  缺陷 4  Editor/Workspace/ProjectWorkspace.swift:212  解码静默失败后覆盖可恢复数据

其余 12 条本轮不要碰，尤其不要碰缺陷 1（输入法，动的是 revision 契约，必须单独
一轮）。文档「## 潜在不一致」一节也不要动，它涉及九处调用点。

本轮三条各有一个容易做成「半修」的陷阱，文档里都写了，动手前确认你理解：
  缺陷 2 —— 清除要限定到「全新未命名文档 + 示例内容」，不是所有 read；
           并且必须连带重写 MuseTests/DocumentTests.swift:202。
  缺陷 3 —— 不要在 paste 和拖拽两处各写一遍归一，覆写它们共同的汇聚点
           readSelection(from:type:)；字符串操作必须用 .literal。
  缺陷 4 —— 只加 report(...) 是不够的，必须阻止后续 saveSnapshot 覆盖，
           并且要区分「从没存过」和「存过但解码失败」两种状态。

--- 硬性约束 ---

1. 文档「## 不要修改」一节列的那条（复选框命中扫描与绘制分叉）是误报，已被
   复核推翻。不要顺手修。如果你的分析与文档结论矛盾，先写出你的复现步骤给我
   看，不要直接改。

2. 不要新增第二套 Markdown 匹配器。Parsing/TokenScanner.swift:7 写着「不再维护
   第二套 CommonMark 匹配器」。（本轮不涉及解析层，但缺陷 3 的行尾归一容易让人
   想去写行扫描——不要。）

3. 不要修改 Muse.xcodeproj/project.pbxproj。项目用
   PBXFileSystemSynchronizedRootGroup，源码目录下的新文件自动进编译。

4. 禁止访问 layoutManager / NSLayoutManager。那会不可逆地进入 TextKit 1 兼容
   模式。产品代码用显式 NSTextLayoutManager 手工栈。

5. 渲染属性的写入必须包在 suppressUndo 里，不进撤销栈。

6. 不要 commit、不要 push、不要新建分支。改完留在工作区，我自己审。

7. 只改本轮范围涉及的代码。不做无关重构、不重排 import、不改格式。

--- 验证要求 ---

本机 xcode-select 指向 CommandLineTools，所有命令必须前置 DEVELOPER_DIR
（不要 sudo xcode-select -s）：

  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

  xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'

当前基线：全量 288 tests / 13 suites 全绿。**本轮必须跑全量**——缺陷 3 改的是
文本进入 storage 的入口，影响面覆盖渲染与解析，只跑 DocumentTests 不足以证明
无回归。

⚠️ 跑单个测试时 ID 必须带括号，例如
  -only-testing:'MuseTests/DocumentTests/reopenedDocumentIsCleanAfterRead()'
漏掉括号时 xcodebuild 会匹配 0 个测试，却依然打印 ** TEST SUCCEEDED **。
每次都看 "Test run with N tests" 那行确认真的跑了。

每条缺陷都必须做**双向**变异验证，并把结果报给我：

  缺陷 2：正向——模拟从自动保存内容恢复（设 autosavedContentsFileURL 后 read），
         断言 isDocumentEdited == true。
         变异——把判据改回无条件清除，该断言必须变红。
         反向变异——把判据收紧成「永不清除」，「全新文档+示例内容 → clean」
         那一半必须变红（否则等于把原有意图丢了也没人发现）。

  缺陷 3：正向——分别粘贴含 \r\n、孤立 \r、U+2028 的文本，断言 storage 里只有
         \n；再对 lineEnding == .crlf 的文档走完整存盘，断言磁盘字节里没有
         \r\r\n。另外单独断言**拖放**路径三种输入结论一致。
         变异——把归一里的 .literal 去掉，CRLF 那条必须变红。
         反向变异——把归一扩大到「把所有 \r 和 \n 都删掉」，正常多行文本的
         断言必须变红。

  缺陷 4：正向——往 store 里塞一段无法解码的数据，调 restoreProjects()，断言
         ① 有 error 被 report ② 随后调 addProject 后原始 blob 仍在 store 里。
         同时断言 load() 返回 nil 时不 report、不阻止保存。
         变异——把阻止覆盖的标志去掉，①仍绿而②必须变红（这一条专门守
         「只报错、没防覆盖」这种半修）。

报告里请**逐条列出对现有测试的修改**，包括「把某条断言的输入从 X 改成 Y」这类
retarget。DocumentTests.swift:202 的 reopenedDocumentIsCleanAfterRead() 正把缺陷 2
的错误行为断言成正确行为，它变红不是回归、是它本身要重写——但你要明确写出你把
它改成了什么。

不要为了让测试变绿而放宽断言。如果某条断言写不出来，停下来告诉我原因。

--- 交付 ---

改完给我：
  1. 每条缺陷改了什么、为什么这么改（一两句）
  2. 每条缺陷的双向变异验证结果（注入后测试是否变红，失败断言数）
  3. 新增/修改了哪些测试，以及它们各自能抓住什么样的错误
  4. git diff --stat

如果中途发现文档里某条描述与实际代码不符，**停下来告诉我，不要自行改变方案**。
这份工单没有跑过 AppKit 探针实测，初版 16 条里已经有 3 条判定过重被我改了，
所以你发现第 4 条是完全可能的——那种情况下我要的是你的复现步骤，不是你的猜测。
````

**后续轮次的改法**：把「本轮范围」和「验证要求」里的缺陷编号替换成下一阶段，其余不动。

- **第一轮**：缺陷 2、3、4（P0 数据丢失）
- **第二轮**：缺陷 5、6、7 + **共因 A**（表格闸门）—— 先补共因 A 再补各自闸门，顺序反了会让你以为闸门没生效
- **第三轮**：缺陷 9、10、11 + **共因 B**（解析层容器前缀）—— 9 和 10 用同一个辅助函数，修法依据是 `MarkdownSemantics.swift:672`；11 根因不同，不要混
- **第四轮**：缺陷 8、12、13（坐标与性能）—— 12 必须连带加长 `PerformanceTests.swift:30` 的引用块语料
- **第五轮**：缺陷 1（输入法）—— 单独一轮，且需要真机中文输入法人工过一遍
- **待确认轮**：缺陷 14、15 —— 先按文档里的「复现方法」跑一次，复现不出来就来问
- **独立立项**（不进任何一轮）：`## 潜在不一致` 的 `token.line` 九处统一；`## 不要修改` 里那条规范性重构

---

## 第一轮核验结果（2026-08-31）

第一轮（缺陷 2、3、4）由 Codex 实施完毕，本节是对那次交付的核验记录。

**核验方式** —— 与工单本体不同，这一节**跑了 AppKit 探针实测**：

- 逐条读 diff，再往外读一层「改动会碰到什么」：`read()` 里既有的清脏点、仓库里已有的换行归一实现、拖放入口的既有行为。
- `git worktree add /tmp/muse-baseline HEAD --detach` 建干净树，同一个探针在**三棵树**上跑（干净 HEAD / 带修复 / 带修复再删一行），用来区分「修复引入的」与「本来就有的」。
- 探针用完即删，未进仓库。

**结论**：

| 缺陷 | 结论 | 说明 |
|---|---|---|
| 2 · 无条件清脏擦掉崩溃恢复 | **通过** | 门拦在正确位置，无回归，无覆盖缺口 |
| 3 · 粘贴/拖放不做行尾归一 | **方向对，但引入崩溃** | 见 R1，必须回炉 |
| 4 · 解码失败后覆盖可恢复数据 | **半修** | 见 R2，阻止实现了，出路没实现 |

全量测试 295 tests / 13 suites，其中 `PerformanceTests.perf200KB()` 失败 —— **与本轮无关**，见 R6。

---

### R1 · 缺陷 3 的修复让「粘贴后按 ⌘Z」崩溃（P0，必须回炉）

**位置**：`Editor/EditorTextView.swift:1549`

```swift
let range = selectedRange()
guard shouldChangeText(in: range, replacementString: replacement) else { return false }  // :1549
super.insertText(replacement, replacementRange: range)                                   // :1550
```

**根因**：`insertText(_:replacementRange:)` **内部自己就会走一遍** `shouldChangeText` / `didChangeText`。`:1549` 这一笔手写的 `shouldChangeText` 没有配对的 `didChangeText()`，于是一次粘贴注册了**两笔**撤销。

**现象**：粘贴后按一次 ⌘Z 崩溃 ——

```text
NSRangeException: -[NSBigMutableString substringWithRange:]:
Range {5, 3} out of bounds; string length 5
```

第一步撤销把插入的 3 个字符移除（串长回到 5），第二笔多余的撤销再去读 `{5, 3}` → 越界。未保存的整篇正文随进程一起没。

**三棵树的实测对比**。探针：串 `"start"`、光标在末尾、粘贴 `"a\r\nb"`、循环撤销到 `canUndo == false`：

| 树 | 归一 | ⌘Z |
|---|---|---|
| 干净 HEAD `7920dee` | ✗ `"starta\r\nb"` | ✓ 1 步回到 `"start"` |
| 第一轮交付 | ✓ | **✗ 崩溃** |
| 交付版删掉 `:1549` | ✓ `"starta\nb"` | ✓ 1 步回到 `"start"` |

第一行顺带**正向确认了缺陷 3 本身是真的** —— 干净树上 CRLF 原样进了 storage。

**改法**（已在独立 worktree 上验证）：**删掉 `:1549` 一行**，只留 `insertText`。删完之后 ——

- 第一轮新增的四条归一测试**全部仍绿**，含字节级的 `pastedCRLFDoesNotBecomeDoubleCarriageReturnOnCRLFSave()`；
- 撤销恢复成一步；
- delegate 否决权**不丢** —— `insertText` 内部会调 `shouldChangeText`，`CLAUDE.md`「不许用手写 `isEditable` 检查代替 `shouldChangeText`」那条不破。`0bf88b8` 的 commit 正文写明这个入口「同时覆盖 `isEditable` 与 delegate 否决」，说的就是它。

另一种等价改法是保留手写 `shouldChangeText`、自己改 `textStorage`、再显式 `didChangeText()`。它更长，且把 `insertText` 已经做好的事重做一遍，不推荐。

**工单自身的责任**：缺陷 3 的「建议改法」写的是「走 `shouldChangeText` / `insertText` 路径写入」—— 那个斜杠的自然读法就是两个都调。应当写成「用 `insertText(_:replacementRange:)` 单一入口，它内部已含 `shouldChangeText`，不要在外面再调一次」。

**这一轮最该记住的一条**：新增的四条测试**全部只断言 `storage.string` 的内容，没有一条碰撤销**。所以这个崩溃干干净净地通过了它自己的双向变异验证。**变异验证只能守住被断言的那个性质** —— 注入变异能证明「这条断言有效」，不能证明「这个改动是安全的」。后续轮次凡是覆写 `NSResponder` / `NSTextView` 命令入口的，验证清单里必须显式加一条撤销断言。

---

### R2 · 缺陷 4 只修了一半：阻止了覆盖，但没有出路（P1，必须回炉）

**位置**：`Editor/Workspace/ProjectWorkspace.swift:30` / `:217` / `:281`

`unresolvedProjectStoreError` 只写不清 —— 全文只有三处：`:30` 声明、`:217` 赋值、`:281` 读取并抛出。**没有任何一处把它清掉。**

**后果**：store 一旦解码失败，`saveSnapshot` 在本进程内**永远**抛错，侧栏无法持久化任何改动（添加、删除、重排全部失败）。而且跨重启依旧 —— 坏 blob 还在原地，下次启动重新走一遍同样的路。加上 `report` 用的是 `JSONDecoder` 的通用 `localizedDescription`（「数据格式不正确」），用户完全看不出侧栏已经被锁死，只会看到自己添加的文件夹重启后又没了。

数据保住了（这是工单的主体要求，达成），可用性换掉了。

**工单自身的责任**：这一条工单写的是「阻止后续 `saveSnapshot` 覆盖，**直到用户确认**」—— 「用户确认」是什么、由谁触发、清掉哪个状态，一个字都没规定。实现方按字面只做了前半句，是工单欠明确。

**建议改法**（不需要新 UI）：把坏 blob 备份到另一个 key（例如 `<原 key>.corrupt-<时间戳>`），备份成功后**放行**覆盖，并把「原数据已备份到 X」写进 `presentedError`。这样：

- 可恢复数据仍在（备份里），满足工单本意；
- 侧栏立刻可用，不锁死；
- 用户拿到的是一句可执行的话，而不是一句 `JSONDecoder` 的通用报错。

**验证**：
- 正向 —— 塞入无法解码的数据，`addProject` 之后断言 ① 备份 key 里是原始字节 ② 主 key 已是新快照 ③ `presentedError` 里含备份位置。
- 断言不误伤 —— `load()` 返回 nil 时不报错、不备份、不阻止保存（现有的 `missingStoredProjectsAreSilentAndDoNotBlockSaving()` 已覆盖，保留）。
- 变异 —— 让备份写入失败（抛错），必须回落到「阻止覆盖」而不是「照样覆盖」；这一条守「备份没成功却已经把原数据盖掉」。

---

### R3 · 换行归一写成了第二份实现（低，但属于 `CLAUDE.md` 点名的坑）

`EditorTextView.swift:1554` 的 `normalizedLineEndings` 硬编码了 `"\r\n"` / `"\r"` / `"\n"`，而 `Document/MuseDocument.swift:85-91` 早就有 `public nonisolated enum LineEnding`（`.lf` / `.cr` / `.crlf` + `.string`），`:193-196` 就是用它做同一件事的。`LineEnding` 是 `public`，`Editor/` 完全可达 —— 这份重复是可避免的。

`0bf88b8` 的 commit 正文里，「文件行尾归一（`MuseDocument.LineEnding` + `dominantLineEnding(in:)`）」就是当初为这件事引入的类型。

两份实现已经开始分叉了：文档层只认 CR / CRLF（`dominantLineEnding` 明确注掉「NEL / LS / PS 不是 CommonMark 的换行，不参与投票」，`DocumentTests.swift:91` 断言了这一点），粘贴层认 CR / CRLF / LS / PS 但**不认 NEL**。三套口径。

**建议**：粘贴层改用 `MuseDocument.LineEnding` 的常量，把「哪些字符算行终止符」收敛到一处。

---

### R4 · NEL（U+0085）漏了（低）

探针实测：粘贴 `"alpha\u{0085}beta"` 之后，`storage.string.unicodeScalars.contains("\u{0085}") == true`。

与 U+2028 同一类问题 —— cmark 不认它是换行，而文档层原样写盘（`data(ofType:)` 只把 LF 还原成记下的终止符，不碰 NEL）。`CLAUDE.md` 里 `⌃Return` 那条硬约束防的就是这类字符从别的入口溜进 storage。

**建议**：并进 R3 一起改，在收敛后的那一处补上 U+0085。

---

### R5 · 富文本粘贴现在一律降级为纯文本（超出工单范围，但方向正确）

新的 `readSelection` 覆写只要拿到 `.string` 就走纯文本插入，于是从浏览器/Word 粘过来的带样式文本不再携带属性进 storage。这与「只有一份可变正文、样式全部由渲染层叠加」的总不变式一致，是好事 —— 但它是工单没要求的行为变更，记在这里以免下次有人当成回归。

注意 `make()` 里 `isRichText` 刻意保持为 true（`:394` 附近注释：「富文本必须保留（属性渲染依赖）」），指的是**视图**要能显示属性，不是要接受粘贴进来的属性。两件事不矛盾。

---

### R6 · `perf200KB()` 在 Debug 下失败，与本轮无关（预先阻碍，建议第二轮之前处理）

`MuseTests/PerformanceTests.swift:204` 的 `#expect(parseMs + applyMs < 500)` 对 Debug 和 Release 用**同一个**门槛。实测：

| 配置 | 扫描+索引 | 属性应用 | 合计 | 结果 |
|---|---|---|---|---|
| Debug · 第一轮交付 | 187.1 ms | 330.0 ms | 517.1 ms | ✗ |
| Debug · 干净 HEAD `7920dee` | 202.0 ms | 357.8 ms | 559.8 ms | ✗ |
| Release · 第一轮交付 | 70.5 ms | 335.3 ms | 405.9 ms | ✓ |

**不是本轮的回归** —— 干净 HEAD 上同样失败，而且更差。根因就是 `perf1MBSmoke` 注释里已经写明的那件事：Debug 下 swift-markdown 带编译器插桩，解析从 70ms 涨到 187–202ms，撞破共用门槛。真门槛（Release）达标。

**建议**：把 `measure(kb:)` 对齐成 `perf1MBSmoke` 已有的分档写法（`#if DEBUG` / `#else` 两个阈值）。不改的话，后续每一轮的「全量测试必须绿」都会被这一条挡住，而它给出的是假红。

这条不属于任何缺陷，**独立立项**。

---

### 已排除的担忧（不要再查这两条）

核验时怀疑过、实测证明不存在的：

- **file URL 拖放会被新覆写当文本截走** —— 不会。只含 file URL 的剪贴板上 `string(forType: .string)` 返回 **nil**（类型列表里只有 `public.file-url` / `NSFilenamesPboardType` / `Apple URL pasteboard type` 等，没有 `.string`），覆写落回 `super.readSelection`。
  - 顺带记录一个**既有**行为（HEAD 就有，不是本轮引入、也不在本轮范围）：拖一个文件进编辑器，插入的是裸 `file:///…` URL 文本，而不是 Markdown 图片语法。
- **缺陷 2 的门会让「正常打开文件」变成 dirty** —— 不会。`read()` 在 `:202` 的 `defer` 里本来就有一笔 `updateChangeCount(.changeCleared)`，正常打开路径不依赖 `makeWindowControllers`。顺序是 `read` 清脏 → AppKit 打 `.changeReadOtherContents` → `makeWindowControllers` 不再擦，三步都对。
  - 且删掉的 `reopenedDocumentIsCleanAfterRead()` **没有留下覆盖缺口**：`readReplacesWholeContent()`（`DocumentTests.swift:111-117`）仍在断言 read 之后 `!isDocumentEdited`。

一处不影响结论的小瑕：`autosavedRecoveryRemainsDirtyAfterMakingWindowControllers()` 的注释把 `.changeReadOtherContents` 说成是 `init(for:withContentsOf:ofType:)` 打的，实际是 AppKit 的 reopen 恢复流程。注释已声明自己是模拟，判断不受影响。

---

### 附录 · 回炉用的 prompt

````text
仓库：/Users/coma_white55/workspace/muse
文档：docs/m5-code-review.md —— 先读「## 第一轮核验结果（2026-08-31）」整节。

第一轮（缺陷 2、3、4）你已经改完，核验发现两条必须回炉、两条建议一起收尾。
本轮只做 R1、R2、R3+R4、R6 四件，其余一律不动。

环境（本机 xcode-select 指向 CommandLineTools，不加这行 xcodebuild 会报
"requires Xcode"；不要 sudo xcode-select -s）：

  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

---

R1（P0，最高优先）：删掉 Editor/EditorTextView.swift:1549 那行手写的 shouldChangeText。

  粘贴后按一次 ⌘Z 会崩：
    NSRangeException: -[NSBigMutableString substringWithRange:]:
    Range {5, 3} out of bounds; string length 5

  insertText(_:replacementRange:) 内部自己就会走 shouldChangeText / didChangeText。
  :1549 这一笔没有配对的 didChangeText()，一次粘贴注册了两笔撤销，第二笔去读已经
  被第一笔移除的区间。

  改法已经在独立 worktree 上验证过：删掉 :1549 一行、只留 insertText —— 归一照常、
  撤销恢复成一步、你那四条归一测试（含字节级 CRLF 存盘那条）全部仍绿。
  不要改成「手写 shouldChangeText + 自己改 textStorage + didChangeText()」，
  那是把 insertText 已经做好的事重做一遍。

  delegate 否决权不会丢：insertText 内部会调 shouldChangeText。

R2（P1）：ProjectWorkspace 的 unresolvedProjectStoreError 现在只写不清
  （:30 声明 / :217 赋值 / :281 抛出，没有第四处），侧栏一旦解码失败就永久无法
  持久化任何改动，且跨重启依旧（坏 blob 还在原地）。

  改成：把坏 blob 备份到另一个 key（<原 key>.corrupt-<时间戳>），备份成功后
  放行覆盖，并把「原数据已备份到 X」写进 presentedError。
  只有备份写入失败时才回落到「阻止覆盖」。

R3 + R4（低，一起改）：把行尾归一收敛到一处。
  EditorTextView.swift:1554 的 normalizedLineEndings 硬编码了 "\r\n" / "\r" / "\n"，
  而 MuseDocument.LineEnding（public nonisolated，Editor/ 可达）就是当初为这件事
  引入的类型。改用它的常量，并在收敛后的那一处补上漏掉的 NEL（U+0085）。

  注意现状是三套口径：文档层只认 CR/CRLF，粘贴层认 CR/CRLF/LS/PS 但不认 NEL。
  收敛之后 DocumentTests.swift:91 那条「NEL/LS/PS 不参与终止符投票」的断言仍必须
  绿 —— 「哪些字符要归一成 LF」和「文件用哪种终止符写回」是两个问题，不要合并。

R6（独立，只改测试）：MuseTests/PerformanceTests.swift:204 的
  #expect(parseMs + applyMs < 500) 对 Debug 和 Release 用同一个门槛。Debug 下
  swift-markdown 带编译器插桩，实测 517–560ms，是假红；Release 实测 405.9ms 达标。
  照隔壁 perf1MBSmoke 已有的写法改成 #if DEBUG / #else 两档，Debug 档取 900。

---

硬约束：

1. 不要碰 Muse.xcodeproj/project.pbxproj（项目用 PBXFileSystemSynchronizedRootGroup，
   新文件放进目录即自动进 target）。
2. 不要动缺陷 2 的那部分 —— 它已通过核验。
3. 不要动 docs/ 下的任何文档。
4. 不要顺手改工单「## 不要修改」和「## 潜在不一致」两节点到的东西。
5. 不要在本轮碰缺陷 5~15 的任何代码。

验证要求：

1. R1 必须新增一条撤销断言：粘贴含 CRLF 的文本后按一次撤销，断言 ① storage 回到
   粘贴前 ② canUndo 变为 false。两个都要 —— 只断言内容抓不到「多注册了一笔」。
   这一条是本轮的重点：上一轮四条新测试全部只断言 storage 内容，崩溃因此漏网。
2. 每条改动做双向变异验证：注入原缺陷必须变红；把修复反向放大也必须变红
   （例如 R2 里让所有状态都阻止保存、R3 里把所有 \r 和 \n 都删掉）。报失败断言数。
3. 全量测试：
   xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'
   R6 改完之后 Debug 全量必须真绿。看「Test run with N tests」那行确认真的跑了 ——
   单个测试的 -only-testing ID 必须带括号，漏括号会匹配 0 个测试却依然打印
   ** TEST SUCCEEDED **。

改完给我：
  1. 每条改了什么、为什么这么改（一两句）
  2. 每条的双向变异验证结果（注入后是否变红、失败断言数）
  3. 新增/修改了哪些测试，各自能抓住什么样的错
  4. git diff --stat

如果发现本节某条描述与实际代码不符，停下来告诉我，不要自行改变方案。R1 的三棵树
对比、R4 的 NEL、R6 的三组数字都是探针实测的；但 R2 的备份方案我没有实测过 ——
那一条如果在实现中发现更好的做法，先说再改。
````

**回炉之后的下一步**：R1、R2 收掉之后，第一轮才算真正完成，再按「后续轮次的改法」进第二轮（缺陷 5、6、7 + 共因 A）。
