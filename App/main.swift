import AppKit

// M0 验证工程的纯 AppKit 入口（M1 起换为 SwiftUI 外壳 + AppKit 文档生命周期组合）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
