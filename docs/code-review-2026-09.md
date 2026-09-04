# 全量 code review 记录（2026-09-03）

来源：对全部生产代码（`Document/` `Parsing/` `Rendering/` `Editor/` `App/`，约 15.5k 行）的一次整体审查。缺陷集中在 `658b567`（侧边栏文件操作 + 远程图片加载）与 `1cce372`（MathJax 公式渲染）两个提交。

全部四个批次均已修复，当前没有遗留条目。

## 已验证无问题（不必重查）

深色模式无陈旧色（SVG 渲成黑色后用 `.sourceIn` + 外观已解析的 `BlockVisualPalette` 快照重新着色）；`preparationWaiters` 信号量在各种交错下正确；`.museImageURL` 往返在 file 与 http URL 上都匹配；无 TextKit 1 回落、无 `.attachment` 误用、无 `NSTextView.draw` 画块视觉；公式写入全部包在 `suppressUndo` 里；新属性 key 在 `Theme.swift` 里正确声明 `public nonisolated`；测试仍是纯 Swift Testing。
