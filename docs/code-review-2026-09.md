# 全量 code review 待修清单（2026-09-03）

来源：对全部生产代码（`Document/` `Parsing/` `Rendering/` `Editor/` `App/`，约 15.5k 行）的一次整体审查。缺陷集中在 `658b567`（侧边栏文件操作 + 远程图片加载）与 `1cce372`（MathJax 公式渲染）两个提交。

按主题分批修，每批独立提交。**行号会随修改漂移，定位以符号名为准。**

修复顺序：侧边栏 → 依赖与重复实现。

## 批次三：侧边栏与 Workspace

- [ ] `Editor/Workspace/WorkspaceNodeRow.swift` `activate()` —— 无条件调用 `actions.focus(node)`，把 0×0 的 `WorkspaceCommandResponder` 设成窗口 first responder。`openFile` 走的是同窗口原地导航（`display: false`），没有新窗口夺回 key 状态，`Task { await Task.yield(); makeFirstResponder(responder) }` 落在 `EditorTextView` 之后。结果：点侧边栏文件打开后没有光标、按键发出蜂鸣，**⌘V 把剪贴板文件粘贴进项目根目录**而不是往文档里粘文本，⌘N 走 `newWorkspaceFile` 而不是 `newDocument`。`validateUserInterfaceItem` 除 `copy(_:)` 外一律返回 true，没有任何门禁。因为是竞态所以时好时坏；展开文件夹也会触发；侧边栏收起时该 responder 仍在链上（`EditorShellView` 只设了 `.frame(width: 0)` + `.allowsHitTesting(false)`）。
- [ ] `Editor/Workspace/ProjectWorkspace.swift` `rename` —— 从 `validatedName(rawName, kind:)` 换成了无扩展名的 `validatedName(rawName)`，丢掉 `.md` 默认，但下游 `canOpen` 的扩展名门禁没同步放宽。用户重命名时只输名字（不输扩展名）会在磁盘上留下无扩展名文件；`WorkspaceTreeLoader` 按 `isRegularFile` 仍然列出该行，但点击会被 `Constants.readableExtensions` 拒绝，提示「Muse 目前只能打开 Markdown 或纯文本文件。」，且应用内除了再改名带上 `.md` 没有别的出路。重命名正是在这个提交里第一次接入 UI。
- [ ] 侧边栏文件操作没有 undo，删除没有确认。`moveToTrash` 现在返回废纸篓 URL，但所有调用方都把返回值丢掉了 —— 撤销删除的钩子已经具备却没接。
- [ ] `focusedNode` 是 `selectedFileURL` 之外的第二份选中态，⌘C 可能复制到与高亮行不同的节点。

## 批次四：依赖、重复实现与清理

- [ ] **解析依赖被换成了未发布的个人 fork**：`project.pbxproj` 指向 `github.com/aleroot/swift-markdown.git` 且锁在裸 revision `f8788449…`（原为 `swiftlang/swift-markdown`，`upToNextMajor 0.6.0`），`Package.resolved` 把 `swift-cmark` 从 tag 0.8.0 换成**移动的 `gfm` 分支**。fork 是承重的（官方 0.8.0 的 `ParseOptions` 没有 `parseMath`，也没有 `InlineMath`/`BlockMath` 节点），但构建已不可复现、没有上游安全更新路径，且 `CLAUDE.md` 仍写着「swift-markdown 0.8.0」。至少 fork 到自己账号并打 tag 锁死，同步修文档。
- [ ] 违反「避免重复实现」，均源于公式被写成块图片的平行拷贝而非复用：`inlineMathFrames` vs `drawInlineMathVisuals`（度量/绘制两套几何，必须像素一致否则被 TextKit 裁切）；`mathParagraph` vs `imageParagraph`；两条异步资源流水线；`MathSyntaxWalker.byteRange`/`lineIndex` 重复 `SemanticWalker` 的实现；「是否 display math」在五处重新推导、四种不同 `default:` 答案；三种路径包含判断（`standardizedFileURL` 前缀 / `pathComponents` / `resolvingSymlinksInPath`），对符号链接项目根结论不一致。
- [ ] 死代码与半迁移：`cachedLocalImage`、`prepareImage(destination:baseURL:)`、`MathRenderArtifact.descent` 无调用方；`WorkspaceProjectTree` 带了两份 `revealInFinder`。
- [ ] `MathRenderRequest.fontSize` 与它本可由 `display` 纯函数推出的值并列存储，memberwise init 能构造出永远匹配不上的缓存键。
- [ ] `WKWebView.callAsyncJavaScript` 可替掉约 120 行 Swift + 15 行 JS 的手写请求/应答关联逻辑。

## 已验证无问题（不必重查）

深色模式无陈旧色（SVG 渲成黑色后用 `.sourceIn` + 外观已解析的 `BlockVisualPalette` 快照重新着色）；`javascriptLiteral` 的 JSON 转义可靠；`preparationWaiters` 信号量在各种交错下正确；`.museImageURL` 往返在 file 与 http URL 上都匹配；无 TextKit 1 回落、无 `.attachment` 误用、无 `NSTextView.draw` 画块视觉；公式写入全部包在 `suppressUndo` 里；新属性 key 在 `Theme.swift` 里正确声明 `public nonisolated`；测试仍是纯 Swift Testing。
