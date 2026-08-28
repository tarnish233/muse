# Muse M3 光标交互报告

- 完成日期：2026-08-28
- 对照方案：`tech-plan.md` v0.6
- 结论：**通过**

## 1. 退出条件

| 条件 | 结果 | 证据 |
|---|---|---|
| marker 光标回显 | ✅ | 光标进入块行或行内内容时回显对应源码 marker；离开后恢复即时渲染 |
| 方向键 | ✅ | 保留 `NSTextView` 原生移动；真实窗口验证左右方向键可进入、穿过并离开有序列表 `1.` marker |
| 鼠标命中 | ✅ | 不重写 hit testing；真实窗口验证点击隐藏列表 marker 附近可正确定位光标并回显源码 |
| 跨行选区 | ✅ | 非空选区按与块源码范围相交判断，所有被选中行的块 marker 同时回显 |
| 源码模式 | ✅ | 同一 `NSTextStorage` 上切换派生属性；菜单与 `⌘/` 可用，编辑、撤销和切回即时渲染正常 |
| 无 TextKit 1 fallback | ✅ | 产品代码未访问 `.layoutManager` / `NSLayoutManager`；继续使用显式 `NSTextLayoutManager` 手工栈 |

## 2. 实现决策

M3 没有自建光标、鼠标或选择系统。`NSTextView` 继续独占键盘导航、hit testing、选区、输入法和 undo；Muse 只在 `textViewDidChangeSelection` 后读取系统给出的 `NSRange`，更新可丢弃的 marker 属性。这避免了与 AppKit 原生编辑语义分叉。

跨行选区的旧实现只检查 `selection.location` 所在行，因此第二行及之后的列表、引用 marker 仍会隐藏。现在块级 token 使用完整块范围与非空选区求交；代码围栏仍按整个围栏块处理，行内 token 继续按 marker/content 范围处理。

源码模式没有维护第二份 Markdown 字符串。`RenderEngine.PresentationMode` 只决定向唯一 `NSTextStorage` 写“即时渲染属性”还是“统一源码属性”。切换时关闭 undo registration，不修改字符、不触发文档 dirty；源码模式中的后续编辑仍走同一后台 revision 管线，并按源码属性增量应用。

为避免干扰中文输入，协调器分别记录“目标模式”和“已应用模式”。如果切换发生在 `hasMarkedText == true` 的候选态，只记录目标模式；组合输入结束后的选区回调再应用属性。

## 3. 产品入口

- 菜单：`显示 → 源码模式`
- 快捷键：`⌘/`
- 菜单项使用 AppKit validation 跟随当前编辑窗口更新勾选状态；没有编辑窗口时禁用。

## 4. 自动化验证

本轮新增 5 项回归测试：

1. `crossLineSelectionRevealsEverySelectedBlockMarker`
2. `sourceModeShowsLiteralMarkdownWithoutBlockDecorations`
3. `renderedModeRestoresPreviewAfterSourceMode`
4. `sourceModeToggleDoesNotChangeOrDirtyDocument`
5. `editsRemainLiteralWhileSourceModeIsActive`

全量结果：

| 配置 | 结果 | 200KB `prepare` | 200KB 脏行应用 | 协调器单键路径 |
|---|---|---:|---:|---:|
| Debug | **120 tests / 8 suites，通过** | 149.377ms | 3.265ms | 169.902ms |
| Release | **120 tests / 8 suites，通过** | 54.829ms | 0.955ms | 70.414ms |

Release 单键路径继续低于技术方案的 150ms 样式落地目标，源码模式没有引入额外正文副本或新的解析路径。

## 5. 真实窗口验收

使用当前唯一运行的 Muse 实例完成以下操作：

- 在有序列表首项中用左右方向键进入 `1.` marker，再返回正文，光标连续且 marker 正常回显；
- 点击隐藏列表 marker 附近，光标命中当前行并显示源码 marker；
- 跨行选择第一、第二个有序列表项，两行 `1.` / `2.` 同时显示，选区高亮连续；
- 从“显示”菜单进入源码模式，确认完整 Markdown 标记可见；
- 使用 `⌘/` 双向切换，源码模式中插入字符后 `⌘Z` 可一次撤销，切回后即时渲染恢复。

验收过程中始终只保留一个 Muse 进程。

## 6. 边界与后续

- M3 只负责光标与呈现交互；列表 Enter 续行/退出、标题行为、自动配对和 checkbox 点击切换属于 M4。
- M5 仍可继续打磨源码模式的主题、布局和更多产品入口，但 M3 的基础退出条件已经满足。
- M0-3 的完整中文 IME 与 VoiceOver 人工矩阵仍未关闭。本轮只证明模式切换不会在 marked text 期间应用属性，不应据此宣称 VoiceOver 或所有输入法场景已经验收通过。
- 当前辅助功能树能读到正文，但样式标记的朗读/重复风险仍需在 M0-3 用真实 VoiceOver 逐项确认。
