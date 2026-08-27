# Muse 工作区与侧栏重构报告

- 日期：2026-08-27
- 范围：左右侧栏、项目树、项目/文件夹/文件创建逻辑、文档导航
- 设计参照：Codex 的“标题栏侧栏开关 + 项目上下文树”交互

## 1. 结果

旧外壳只有一个写死的 `Muse` 项目和当前 `NSDocument` 行，不能表达真实目录，也不能在项目内创建内容。本轮将其替换为独立的工作区导航层，同时保留 `NSDocument` 作为每篇文稿的官方生命周期实现。

### 标题栏

- 删除编辑器内容区内悬浮的右侧栏按钮。
- 删除编辑窗口的 `NSToolbar`；系统工具栏产生的圆形按钮底座不再参与渲染。
- 使用 46pt 自绘三段标题栏：左段属于项目栏，中段显示文稿图标和标题，右段属于大纲栏；竖向边界贯穿窗口顶部。
- 左侧开关固定在交通灯之后，右侧开关固定在窗口最右侧。按钮为 28pt ghost button，默认透明，只有 hover/开启反馈使用低对比填充。
- 两个按钮都带 tooltip 与无障碍描述；侧栏收起后开关仍留在固定位置。

### 自定义三列

- 根布局是 Muse 自己维护的 `HStack`，不使用 `NavigationSplitView` 或 `.inspector`。
- 左右栏均使用 `CodexSidebarSurface`，内容使用 `ScrollView + LazyVStack`，不使用 `.listStyle(.sidebar)`。
- 左右分隔线由 `SidebarResizeHandle` 绘制，视觉宽度 1pt，鼠标命中宽度 9pt。
- 左栏默认 280pt，右栏默认 300pt；两栏均可在 240–380pt 调整。
- 开合从当前画面状态开始，使用无过冲 spring；系统开启“减少动态效果”时切换为近乎即时变化。

### 左侧项目栏

- 顶部只保留“项目”和一个紧邻上下文的 `+` 菜单。
- `+` 菜单提供“新建项目…”与“打开项目…”。
- 每个项目根节点独立展开；文件夹继续递归展开，文件点击后打开文稿。展开箭头、层级缩进和 29pt 行高全部自绘，不使用 `DisclosureGroup` 或 `OutlineGroup`。
- 项目菜单提供新建文件、新建文件夹、在访达中显示、从侧边栏移除。
- 文件夹上下文菜单提供新建文件/文件夹和在访达中显示。
- 没有项目时显示紧凑的 Codex 风格空状态和两个 28pt 操作按钮，不使用系统 `ContentUnavailableView`。

### 右侧大纲

- 不显示“大纲”标题。
- 不显示顶部横线，也不再用额外顶部 padding 为悬浮按钮让位。
- 标题层级继续通过缩进表达；点击标题仍定位到正文。
- 空大纲使用系统空状态视图。

## 2. 官方 API 边界

本轮没有自建窗口、文件选择器或文档注册表：

| 需求 | 使用的系统能力 |
|---|---|
| 三栏结构 | Muse 自定义 `HStack` + `EditorChromeState` |
| 左右栏表面 | `CodexSidebarSurface` + `ScrollView` / `LazyVStack` |
| 宽度调整 | 自定义 `SidebarResizeHandle` / `DragGesture` |
| 自绘标题栏 | `fullSizeContentView` + SwiftUI 三段式表面 |
| 左右栏按钮 | SwiftUI ghost button + 固定几何常量 |
| 新建项目位置 | `NSSavePanel` |
| 打开现有项目 | `NSOpenPanel` |
| 创建/枚举目录与文件 | `FileManager` |
| 项目跨启动恢复 | security-scoped URL bookmark + `UserDefaults` |
| 打开/复用文稿窗口 | `NSDocumentController` |
| 在访达中显示 | `NSWorkspace.activateFileViewerSelecting` |

## 3. 数据与安全语义

- `ProjectWorkspace` 只保存项目 URL、派生目录树和界面错误，不持有文稿正文。
- `WorkspaceNode` 是从磁盘生成的值类型快照；创建后刷新对应项目树。
- 新建普通文件时默认补 `.md`，内容为空，随后交给 `NSDocumentController` 打开。
- 当前支持打开 `.md`、`.markdown`、`.mdown`、`.mkd`、`.txt`、`.text`。
- 从侧边栏移除项目不会删除或移动项目目录。
- 文件树默认跳过隐藏文件与 macOS package 的内部后代。

## 4. 验收

自动测试覆盖：

1. 创建项目、子文件夹和 Markdown 文件；
2. 文件名无扩展名时自动补 `.md`；
3. 文件夹优先与 Finder 自然排序；
4. 移除项目不会删除磁盘目录；
5. 非法名称与不可编辑扩展名判定。

全量 Debug 测试命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project Muse.xcodeproj -scheme Muse -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/muse-derived
```

初版工作区结果为 **114 tests / 8 suites 全部通过**。后续按产品反馈移除全部系统侧栏容器；真实 Debug App 已验证自定义左右栏的关闭、重新打开、按钮两端定位及编辑区连续性，最终仅保留一个运行实例。

## 5. Codex 视觉参照

实现以用户提供的 Codex 截图为第一视觉基准，并参考以下对真实 Codex Desktop 运行界面的开源采样资料：

- [explodex：Codex app shell / sidebar chrome](https://github.com/dan-dr/explodex/blob/main/docs/codex-architecture.md)
- [happy：Codex Design System Notes](https://github.com/slopus/happy/blob/main/packages/codium/design-system.md)

采用的关键采样值包括约 46pt 顶部栏、28–36pt 紧凑按钮、12–13pt 侧栏文本、低透明度 hover 背景和 1pt 低对比分隔线。Muse 只复现布局与交互原则，没有复制第三方业务代码。
