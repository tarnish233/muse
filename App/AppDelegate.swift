import AppKit
import SwiftUI
import MuseKit

/// NSDocument 生命周期应用（M1）：不手动建窗口，开存由 NSDocumentController 管理。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPreferences.applyAppearance()
        MuseDocument.windowControllerFactory = { document in
            EditorWindowController(document: document)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: AppPreferences.openUntitledDocumentKey) as? Bool ?? true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Muse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Muse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Muse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        let newItem = NSMenuItem(
            title: "新建",
            action: #selector(createNewDocumentOrWorkspaceFile(_:)),
            keyEquivalent: "n"
        )
        newItem.target = self
        fileMenu.addItem(newItem)
        let newFolderItem = NSMenuItem(
            title: "新建文件夹",
            action: #selector(WorkspaceCommandResponder.newWorkspaceFolder(_:)),
            keyEquivalent: "n"
        )
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFolderItem)
        fileMenu.addItem(withTitle: "打开…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "存储", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "存储为…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(withTitle: "还原到已存储版本", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        // 原生查找替换：action 走响应链到 NSTextView，tag 是 NSTextFinder.Action。
        let findItem = NSMenuItem()
        editMenu.addItem(findItem)
        let findMenu = NSMenu(title: "查找")
        func finderAction(_ title: String, _ key: String, _ tag: NSTextFinder.Action,
                          modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(NSTextView.performTextFinderAction(_:)),
                keyEquivalent: key
            )
            item.tag = tag.rawValue
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        findMenu.addItem(finderAction("查找…", "f", .showFindInterface))
        findMenu.addItem(finderAction("查找并替换…", "f", .showReplaceInterface,
                                      modifiers: [.command, .option]))
        findMenu.addItem(.separator())
        findMenu.addItem(finderAction("下一个", "g", .nextMatch))
        findMenu.addItem(finderAction("上一个", "g", .previousMatch,
                                      modifiers: [.command, .shift]))
        findItem.submenu = findMenu

        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        let sourceModeItem = NSMenuItem(
            title: "源码模式",
            action: #selector(toggleSourceMode(_:)),
            keyEquivalent: "/"
        )
        sourceModeItem.target = self
        viewMenu.addItem(sourceModeItem)
        viewMenuItem.submenu = viewMenu

        return mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleSourceMode(_:)) else { return true }
        guard let controller = NSApp.keyWindow?.windowController as? EditorWindowController else {
            menuItem.state = .off
            return false
        }
        menuItem.state = controller.isSourceMode ? .on : .off
        return true
    }

    @objc private func toggleSourceMode(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? EditorWindowController else { return }
        controller.toggleSourceMode()
    }

    @objc private func createNewDocumentOrWorkspaceFile(_ sender: Any?) {
        let workspaceAction = #selector(WorkspaceCommandResponder.newWorkspaceFile(_:))
        guard !NSApp.sendAction(workspaceAction, to: nil, from: sender) else { return }
        NSDocumentController.shared.newDocument(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }
}
