# Muse M0–M2 阶段完成情况报告

- 评估日期：2026-08-28
- 评估基线：`aa3a831`
- 评估方法：对照 `tech-plan.md` 的退出条件，核对当前源码、测试、历史真机证据与未回填的人工验收项

## 1. 总结

| 阶段 | 实现完成情况 | 正式状态 | 判断 |
|---|---|---|---|
| M0 技术验证 | 核心技术、自动化和块级绘制地基已完成 | ⚠️ 有条件通过 | 技术路线已经证明可行，但 M0-3 人工 gate 尚未完整执行并回填，不能写成无条件通过 |
| M1 骨架 | 退出条件全部完成 | ✅ 通过 | 文档单一所有权、TextKit 2 手工栈、open/save/autosave、共享框架与 SwiftUI 外壳均有代码和测试证据 |
| M2 解析与渲染 | 退出条件及 M2-1～M2-9 全部完成 | ✅ 通过 | AST 语义收口、后台 revision 管线、行内/块级渲染、列表几何和外观适配均已落地 |

结论不是“M0–M2 全部正式验收完毕”，而是：**M1、M2 已完成；M0 的工程实现已完成，但正式 gate 仍缺人工验收记录。** 当前可以继续 M3 开发，但在把项目描述为“M0–M2 全部通过”或进入发布准备前，必须关闭 M0-3。

## 2. 当前验证证据

2026-08-28 使用当前代码重新执行 Debug 与 Release 全量测试：

| 配置 | 结果 | 关键性能（200KB） |
|---|---|---|
| Debug | **115 tests / 8 suites，通过** | `prepare` 160.716ms；脏行应用 3.384ms；协调器单键 175.332ms |
| Release | **115 tests / 8 suites，通过** | `prepare` 67.907ms；脏行应用 0.977ms；协调器单键 71.256ms |

Release 协调器单键路径低于技术方案的 150ms 样式落地目标，脏行属性应用低于 16ms 主线程预算。Debug 的 175.332ms 高于产品目标但低于 200ms 粗回归防线；产品性能门槛以 Release 为准，Debug 数据只用于发现明显退化。

当前 8 个测试套件为：`SourceIndexTests`、`TokenScannerTests`、`MarkdownSemanticsTests`、`RendererTests`、`CoordinatorPipelineTests`、`PerformanceTests`、`DocumentTests`、`WorkspaceTests`。

## 3. M0：工程完成，正式 gate 未闭合

已完成：

- 显式 TextKit 2 手工栈，无 TextKit 1 fallback 路径；
- Unicode/UTF-8/UTF-16 区间转换与源码字符不变式；
- marker 隐藏/回显、后台 revision、脏行应用和 undo 隔离；
- 块级视觉改走真实 `NSTextLayoutFragment` 路径，并有真实 fragment/位图测试；
- 浅色/深色共享调色板、列表首视觉行锚定、层级符号与序号槽位均已有自动化和局部真机证据；
- Debug、Release 当前全量回归均通过。

未完成：

- `m0-report.md` §6/§9.4 的人工验收结果没有完整回填；
- gate 关键项仍是零宽留白、中文 IME、撤销手感、VoiceOver；
- 鼠标命中、方向键、跨 marker 选择、软换行、主题/外观热切换等也应按表逐项留证。

因此 M0 的准确状态是“**有条件通过**”，而不是“通过”。这不推翻 AppKit + TextKit 2 + swift-markdown 的技术路线，只表示正式验收记录尚不完整。

## 4. M1：通过

退出条件均已满足：

- `MuseDocument → EditorBuffer → NSTextStorage` 保持唯一可变正文；
- `MuseDocument` 直接从 `NSTextStorage` 读写 UTF-8，open/save/autosave/reopen 有 8 项文档测试；
- 渲染属性不标脏、字符编辑会标脏；文件读取完成后清除加载期 change count；
- `MuseKit` 由 App 与测试共同依赖，Debug/Release 均能构建和测试；
- SwiftUI 只负责外壳，编辑核心仍是 AppKit TextKit 2。

最近加入的工作区文档切换继续使用 `NSDocumentController.openDocument(display: false)` 与 `NSDocument` 的窗口控制器迁移 API。它属于 M1 之后的工作区增强，不改变 M1 的正文所有权结论。

## 5. M2：通过

退出条件均已满足：

- `SourceIndex` 解决 UTF-8 source position 到 UTF-16 `NSRange` 的转换；
- swift-markdown AST 是语义与源码定位的唯一来源，`TokenScanner` 只补未闭合编辑态；
- 后台不可变快照 + revision 丢弃过期结果，主线程只应用最新结果；
- 标题、强调、删除线、行内代码、链接、列表、任务框、引用、代码围栏和分隔线均已渲染；
- 块级视觉使用 `MuseLayoutFragment`，测试走 TextKit 2 真实 fragment；
- 列表嵌套缩进、软换行 marker 首行锚定、有序/无序共槽、二级空心符号和 checkbox 配色已有回归测试；
- M2-1～M2-9 的历史收口条件仍成立，当前 Debug/Release 115 项测试均通过。

不属于 M2 的功能不能算作缺口：checkbox 点击修改源码属于 M4，图片预览/表格可视化/语法高亮属于后续阶段。

## 6. 遗留风险与建议顺序

1. **先关闭 M0-3 人工 gate。** 由人工按 M0 报告逐项操作并回填结果；任何失败都应形成独立缺陷和复现步骤。
2. **再进入 M3 光标交互。** marker 前后方向键、鼠标命中、跨行选择和源码模式应优先，因为它们与 M0 的人工风险高度重叠。
3. **M6 前建立稳定性能采样。** 当前 Release 达标，但单次冷构建数据波动明显；正式发布门槛应采用固定机器、预热、重复采样与 P95，而不是单次日志。
4. **补工作区窗口切换的 UI 集成测试。** 当前 `WorkspaceTests` 覆盖文件系统语义，文档在当前窗口切换主要依靠实现审查和人工验证，尚缺窗口级自动化。

