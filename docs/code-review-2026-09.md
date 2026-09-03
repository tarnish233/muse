# 全量 code review 待修清单（2026-09-03）

来源：对全部生产代码（`Document/` `Parsing/` `Rendering/` `Editor/` `App/`，约 15.5k 行）的一次整体审查。缺陷集中在 `658b567`（侧边栏文件操作 + 远程图片加载）与 `1cce372`（MathJax 公式渲染）两个提交。

按主题分批修，每批独立提交。**行号会随修改漂移，定位以符号名为准。**

修复顺序：公式 → 图片/远程资源 → 侧边栏 → 依赖与重复实现。

## 批次一：公式（math）

- [ ] `Parsing/MarkdownSemantics.swift` `MathSyntaxWalker.visitText` —— 探测文档解析的是 `text.string`（cmark **解码后**的字面量），却把探测结果的局部列号直接加到原始源码的字节偏移 `originalRange.lowerBound` 上。同一行公式前面出现任何 `\$` 或 HTML 实体都会让区间整体偏移（`&copy; $x$` 会把 `py;` 当成公式），CJK 场景下偏移还可能落在标量中间、被 `SourceIndex.nsRange` 折成零长区间而静默丢弃。修：照同文件 `appendBlockMath` 已有的做法探测原始 UTF-8 切片（它的注释已经写明这个坑）；注意 `appendBlockMath` 用 `blockMathProbeSource` 把非 `$`/空白字符全替换成 `x` 以避免切片开头被当成块级语法，行内探测需要等价处理。现有 `MarkdownSemanticsTests` 只覆盖了 CJK 与未转义货币符号。
- [ ] `Rendering/RenderEngine.swift` `applyMathVisibility` 块分支 —— 隐藏块公式把 `.museBlock` 与 `.paragraphStyle` 覆盖到整个首段落（含容器前缀）。token 按 `markerRange.lowerBound` 排序，引用 marker 在字节 0、公式 marker 在字节 2，所以公式覆盖掉引用的 `museBlock`，引用竖线、通宽底色与缩进全部消失；`revealSource()` 又是 `removeAttribute(.museBlock)`，回显态也修不回来。
- [ ] `Rendering/RenderEngine.swift` `applyMathStyle` —— `.museMathSourceParagraph` 在按 token 顺序的样式循环里快照 `.paragraphStyle`，但表格 token 的 marker 是**分隔行**，排在表头行之后。表头里的公式因此快照到表格样式生效**前**的 base 段落，之后 `revealSource()` → `restoreInlineMathParagraph` 把这份过期样式写回整段，光标一进入公式表格行就压塌。且 `??` 链优先取存储快照，不会自愈。参考 `applyInlineImageVisibility` 从 `.museBlock` + `.museImageSize` 重建而非快照的做法。
- [ ] `Rendering/BlockLayoutFragment.swift` `drawInlineMathVisuals` / `inlineMathFrames(at:)` —— 基线只用 `line.glyphOrigin.y`，漏加该行的 `line.typographicBounds.minY`；两者都是行片段相对坐标，缺一项则段落软换行后的公式被画在**首个视觉行**的基线上，而第二行预留的 kern 空隙留白。`inlineMathFrames` 同样漏，导致 `renderingSurfaceBounds` 并错矩形、正确区域反而被裁。x 方向同理漏 `typographicBounds.minX`（缩进段落）。同文件 `drawTableRow`、`tableSelectionRects` 都正确加了。现有测试只比同一行内的 x 差值，CI 看不到。
- [ ] `Rendering/MathRenderer.swift` `invalidExpressions` —— 无界、永不裁剪、跨文档的进程级 `Set<String>`，键是公式全文；在公式里每敲一个键就留下一个永久字符串。且 `invalidBridgeResponse` / `invalidSVG` 也涵盖非确定性故障（bridge 应答残缺、`getBoundingClientRect` 返回 0、SVG 解码抖动），一次瞬时故障就把有效公式永久拉黑，连 `resetWebView` 都不清。
- [ ] `Rendering/RenderEngine.swift` `applyMathVisibility` 行内分支 —— 用大 `.kern` 摊在近零宽源码字符上预留宽度，而 CLAUDE.md 已记录「系统选区几何会重复计入 `.kern`」。表格靠 `museTableSelection` + fragment 自绘选区 + 系统选区背景设 clear 解决，公式没有对应补偿（`setUsesCustomTableSelection` 只为表格开启），拖选会高亮出约一个公式宽度的多余蓝条。另：含空格的公式（`$a + b$`）保留内部断行机会，可能被 TextKit 跨行拆开。
- [ ] `Rendering/BlockLayoutFragment.swift` `drawBlockMath` —— `MathRenderRequest` 只按 (display, fontSize, expression) 做键，不含文本容器宽度；容器变窄时 `drawBlockMath` 夹住宽度却保留全高，`image.draw(in:)` 把公式非等比压扁（640pt 产物在 400pt 容器里压到 62% 宽、100% 高），且没有 resize 重渲染钩子，不会自愈。修：绘制时按 `availableWidth` 推等比缩放，或把容器宽度纳入缓存键。
- [ ] 公式渲染是「全有或全无」：`scheduleMathPreparation` 串行 await 每个公式，只在最后一个完成后才置 `needsMathRefresh`。20 个公式的文档会一直显示裸源码直到最慢那个完成，任一个撞上 10s `renderTimeoutTasks` 超时就整页卡住。同一提交里图片路径已明确修好这点（「每张图片准备完成就立即重排」），公式没跟上。
- [ ] 公式路径破了四处已记录的性能规则：① `RenderEngine.refreshMathArtifacts` 为挑出 math 条目做整篇 `tokens.filter` **且**整篇 `computedVisibility`，而它从 `textViewDidChangeSelection` 可达；② `applyMathStyle` / `applyMathVisibility` / `restoreInlineMathParagraph` 每次显隐翻转做 3 + 2N 次 `storage.attribute` 读（~56µs/次）；③ `scheduleMathPreparation` 每次击键在主 actor 上跑整篇 `compactMap` → `Set` → `sorted`，且在 `statusText` 计时窗口之外，读数看不见；④ `renderingSurfaceBounds` 先 `enumerateAttribute` 整个 fragment 再 `guard blockKind != nil` 早退，无公式文档每个滚动帧都要付。

## 批次二：图片与远程资源

- [ ] `Rendering/ImageResolver.swift` 远程下载 —— 20MB 上限从**逐字节流式硬限**退化成**下载完成后**的文件尺寸检查。`Transfer-Encoding: chunked`（`expectedContentLength == -1`）时服务端可以先把任意体积写满磁盘才被拒；`scheduleBlockImagePreparation` 在解析时自动入队，打开文档即触发，无需用户手势，且并发 4 路。被删掉的 `RemoteDataAccumulator` 注释原文就写了「不能改成下载完再检查」。
- [ ] `Rendering/ImageResolver.swift` 远程下载 —— 临时文件在所有路径上都没有 `removeItem(at:)`：成功、MIME 拒绝、超限拒绝、解码失败、重试。async 版 `download(from:)` 把文件所有权交给调用方（与 completion-handler 版不同），因此每次远程下载都泄漏一个 `CFNetworkDownload_*.tmp` 直到进程退出。
- [ ] `Document/RenderCoordinator.swift` `scheduleBlockImagePreparation` —— 去掉 `url.isFileURL` 过滤后，HTTP 拉取进了**每次击键**的解析路径：每个字符都 cancel 在途 `URLSession.download` 并重开连接，且没有 in-flight 去重、没有负缓存。连续输入时远程图片永远下不完（~8 字符/秒 ⇒ 一句话约 80 个 GET 全部半途中止）。失败同样无界：404 / 非 `image/*` 不记录任何状态，整个文档生命周期每次解析都重发；5xx 更糟，`shouldRetry` 为真，每次解析花 3 个请求 + 1.25s `Task.sleep`。修：新旧 URL 集合比对，未变则不 cancel/重启；加 in-flight `[URL: Task]` 注册表与负缓存（参考 `MathRenderer.invalidExpressions`，但要有界）。
- [ ] `Document/RenderCoordinator.swift` `prepareImagesAndRefresh` —— `applyImageRefreshIfPossible()` 被移进 task group 的排空循环，从「每批一次」变成「每张图片一次」，而该函数是整篇 `engine.render` + `revealCache.removeAll()` + `lastReconcileWriteCount = 0`。200KB 文档 20~30 张图会变成 20~30 次串行整篇主线程重渲染（单次约 245ms），对着 P95 < 16ms 的预算掉帧数秒。CLAUDE.md：「`render` 整篇重写，只用于属性全体失效」。修：移回循环外，或改成窄范围刷新（参考同提交为公式加的 `refreshMathArtifacts`）。
- [ ] `Rendering/ImageResolver.swift` `PreparationResult.cacheChanged` —— 两种情况下为 false 但协调器仍需重渲染：① URL 已在缓存中（远程场景下「下载完成但用户已输入」的窗口有数秒宽，`group.next()` 的 guard 直接 `cancelAll(); return` 而不置 `needsImageRefresh`，此后每次解析都走早退，虚线「图片无法加载」框永久留在屏幕上，而解码后的图就在缓存里）；② 文件被删除导致的淘汰（`cache.refresh(at:)` 返回 true 但在 `.failure` 分支被丢弃，陈旧的 560×400 行高保留，占位框画在旧的超大框里）。
- [ ] 块图片像素只活在 `NSCache` 里，而撑起的行高活在 `.museImageSize` 属性里。一次淘汰（超过 129 张图，或系统内存压力）会把图片静默换成虚线错误框、留在超大空行中，且没有重解析钩子。

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
