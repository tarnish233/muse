# 项目开发约定

## 开发阶段与方案选择

- 在开始动手之前可以调研 GitHub 是否有相关项目可以参考；能使用官方库或官方方案时尽量采用，但都仅作为参考，不要脱离用户需求。
- 项目当前处于早期开发阶段，尚未发布任何版本。实现变更时无需维护对旧版本、旧配置、旧数据格式或旧 API 的兼容性；如果有助于简化设计或提高正确性，可以直接进行破坏性更新，并同步更新相关代码、测试与文档。
- 不要为尚未发布的旧配置或旧数据新增迁移器、兼容分支、废弃别名或双写逻辑；修改相关功能时应直接更新到新结构并删除旧实现。

## 核心架构不变式

- 编辑期只能存在一份可变正文：`EditorBuffer.textStorage`。即时渲染只能在源码上叠加属性，不得修改字符、插入附件占位字符或维护第二份可变字符串。
- `Document/`、`Parsing/` 与 `Rendering/` 属于 `MuseKit` 核心层；`App/` 与 `Editor/` 属于应用层。不要让核心层反向依赖应用层。
- Markdown 结构只从 `MarkdownSemantics` 的 swift-markdown AST 获取；不要新增正则或手写解析器。Token 范围是 UTF-8 字节偏移，交给 AppKit 前必须通过 `SourceIndex` 转换为 UTF-16 `NSRange`。
- 产品代码禁止访问 `layoutManager` 或 `NSLayoutManager`，避免不可逆地降级到 TextKit 1。块级视觉必须通过 `MuseLayoutFragment` 绘制；绘制层只消费渲染属性，不得重新解析 Markdown 源码。
- `EditorView.updateNSView` 只能同步派生的呈现状态，不得向 `NSTextStorage` 回写整篇正文。渲染属性更新必须排除在撤销栈与文档脏状态之外。

## 性能

- 性能是编辑器功能的验收条件。输入、选区变化、滚动和即时渲染等高频路径应优先采用局部更新、增量解析与任务合并，避免无必要的整篇扫描、整篇属性重写、重复布局或同步阻塞主线程；不要在 SwiftUI `body`、TextKit 绘制回调等高频入口执行昂贵计算。
- 涉及解析、渲染、TextKit、SwiftUI 状态流或大文档处理的改动，必须运行相关性能测试，并关注 20 KB、200 KB 与 1 MB 文档场景以及连续输入、单键属性落地等指标。若性能明显退化，应先定位并修复，或在交付时明确说明原因和影响。
- 性能结论以 Release 构建为准，Debug 数据只用于发现明显退化。200 KB 文档的目标是输入主线程 P95 小于 16 ms，单键从编辑到样式落地小于 150 ms；脏区不得随文档规模退化为整篇重绘。

## 测试与验收

- 修复缺陷必须增加能复现问题的回归测试。渲染和编辑测试应经过真实 `NSTextStorage`、`NSTextLayoutManager` 或编辑器命令入口，避免只测试与生产路径平行的辅助计算。
- 定向测试通过后仍需运行全量测试。不能只看 `** TEST SUCCEEDED **`，必须确认输出中的实际测试数量不为 0；运行单个 Swift Testing 测试时，测试 ID 必须带 `()`。
- 全量测试命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Muse.xcodeproj -scheme Muse -destination 'platform=macOS'`。
- 性能相关改动还需运行 Release 性能套件：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Muse.xcodeproj -scheme Muse -configuration Release -destination 'platform=macOS' -only-testing:MuseTests/PerformanceTests`。`PerformanceTests` 已串行化，不要另行并发运行多个性能测试进程。
- 真实中文输入法、VoiceOver 和真机交互仍包含人工验收项；自动化测试通过不能代替这些结论。

## 工程与文档

- 工程使用文件系统同步分组。新增或删除普通 Swift 源文件时会自动进入对应 target，不要仅为添加文件而手动修改 `Muse.xcodeproj/project.pbxproj`；产品名、Bundle ID 与构建设置等工程配置变更除外。
- 判断当前行为时以源码和测试为准。`docs/tech-plan.md` 是按时间追加的历史记录，后文可能推翻前文，不得把其中单独一段当作当前实现。

## Debug 运行约定

- 启动新的 Debug 构建前，必须先停止此前运行的 Debug 实例，避免多个调试版本同时存在。Debug 构建的应用显示名和产物名必须带有 `Debug` 后缀（例如 `Muse Debug`），以便与正式版清晰区分；停止旧实例时只匹配 DerivedData 中的 Debug 构建，不得影响正式版应用。
