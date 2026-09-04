# 全量 code review 待修清单（2026-09-03）

来源：对全部生产代码（`Document/` `Parsing/` `Rendering/` `Editor/` `App/`，约 15.5k 行）的一次整体审查。缺陷集中在 `658b567`（侧边栏文件操作 + 远程图片加载）与 `1cce372`（MathJax 公式渲染）两个提交。

按主题分批修，每批独立提交。**行号会随修改漂移，定位以符号名为准。**

剩余修复顺序：依赖与重复实现。

## 批次四：依赖、重复实现与清理

- [ ] **解析依赖被换成了未发布的个人 fork**：`project.pbxproj` 指向 `github.com/aleroot/swift-markdown.git` 且锁在裸 revision `f8788449…`（原为 `swiftlang/swift-markdown`，`upToNextMajor 0.6.0`），`Package.resolved` 把 `swift-cmark` 从 tag 0.8.0 换成**移动的 `gfm` 分支**。fork 是承重的（官方 0.8.0 的 `ParseOptions` 没有 `parseMath`，也没有 `InlineMath`/`BlockMath` 节点），但构建已不可复现、没有上游安全更新路径，且 `CLAUDE.md` 仍写着「swift-markdown 0.8.0」。至少 fork 到自己账号并打 tag 锁死，同步修文档。
- [ ] 违反「避免重复实现」，均源于公式被写成块图片的平行拷贝而非复用：`inlineMathFrames` vs `drawInlineMathVisuals`（度量/绘制两套几何，必须像素一致否则被 TextKit 裁切）；`mathParagraph` vs `imageParagraph`；两条异步资源流水线；`MathSyntaxWalker.byteRange`/`lineIndex` 重复 `SemanticWalker` 的实现；「是否 display math」在五处重新推导、四种不同 `default:` 答案；三种路径包含判断（`standardizedFileURL` 前缀 / `pathComponents` / `resolvingSymlinksInPath`），对符号链接项目根结论不一致。
- [ ] 死代码与半迁移：`cachedLocalImage`、`prepareImage(destination:baseURL:)`、`MathRenderArtifact.descent` 无调用方；`WorkspaceProjectTree` 带了两份 `revealInFinder`。
- [ ] `MathRenderRequest.fontSize` 与它本可由 `display` 纯函数推出的值并列存储，memberwise init 能构造出永远匹配不上的缓存键。
- [ ] `WKWebView.callAsyncJavaScript` 可替掉约 120 行 Swift + 15 行 JS 的手写请求/应答关联逻辑。

## 已验证无问题（不必重查）

深色模式无陈旧色（SVG 渲成黑色后用 `.sourceIn` + 外观已解析的 `BlockVisualPalette` 快照重新着色）；`javascriptLiteral` 的 JSON 转义可靠；`preparationWaiters` 信号量在各种交错下正确；`.museImageURL` 往返在 file 与 http URL 上都匹配；无 TextKit 1 回落、无 `.attachment` 误用、无 `NSTextView.draw` 画块视觉；公式写入全部包在 `suppressUndo` 里；新属性 key 在 `Theme.swift` 里正确声明 `public nonisolated`；测试仍是纯 Swift Testing。
