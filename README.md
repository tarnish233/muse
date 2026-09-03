# Muse

一个 macOS 上的 Markdown 编辑器，写的时候就是渲染好的样子。

Muse 没有「编辑区」和「预览区」之分。你看到的就是 Markdown 源码本身——标题变大、列表有圆点、代码块有底色，而 `#`、`*` 这些语法标记只在光标移到那一行时才显出来。

> ⚠️ 开发中，还没有应用图标，功能也不完整，暂未发布正式版本。

## 特性

- **即时渲染**——标题、强调、行内代码、链接、引用、代码块、分隔线
- **列表**——圆点和序号悬挂在正文左侧，回车自动续项
- **任务清单**——点一下方框就能勾选
- **表格**——对齐渲染，Tab 跳单元格，回车加行，拖拽调整行列顺序
- **图片**——直接显示在正文里，点击放大
- **数学公式**——支持 `$…$` 行内公式与 `$$…$$` 块级公式，光标移入时回显 LaTeX 源码
- **文件树**——侧栏里打开文件夹，新建项目和文件
- **源码模式**——`⌘/` 切回纯文本
- **查找替换**——系统原生
- 跟随深色模式

## 运行

需要 macOS 14+ 和 Xcode 26+。

```bash
git clone https://github.com/tarnish233/muse.git
cd muse
open Muse.xcodeproj
```

然后按 `⌘R`。

## 技术

Swift 6 + AppKit（TextKit 2）+ SwiftUI。Markdown 结构由 [swift-markdown](https://github.com/swiftlang/swift-markdown) AST 提供；公式节点暂时锁定到其[数学语法提案分支](https://github.com/swiftlang/swift-markdown/pull/258)，公式由应用内置的 [MathJax 3.2.2](https://github.com/mathjax/MathJax) `tex-svg-full` 组件异步排版为 SVG，再通过 TextKit 2 原生绘制（运行时不访问 CDN，也不动态加载字体模块）。

整个编辑器只维护一份 `NSTextStorage`：渲染是往源码上叠加属性，而不是生成第二份文本。设计取舍和各阶段报告在 [`docs/`](docs/)。
