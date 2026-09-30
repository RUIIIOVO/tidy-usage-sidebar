import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 默认普通 App（有 Dock 图标）；设置里选择隐藏则回到纯菜单栏模式
        let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
        app.setActivationPolicy(hideDock ? .accessory : .regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var mainWindow: MainWindowController!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        installMainMenu()
        handleArguments()
        store = UsageStore(settings: settings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            // 菜单栏深浅变化（换壁纸 / 切外观）时重画，常态颜色要跟着变
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.renderStatusItem() }
            }
        }

        panel = PanelController(
            rootView: PanelView(store: store, settings: settings) { [weak self] in self?.showSettings() })
        panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }

        mainWindow = MainWindowController(
            rootView: PanelView(store: store, settings: settings,
                                openSettings: { [weak self] in self?.showSettings() },
                                windowMode: true),
            settings: settings)

        settings.$hideDockIcon.dropFirst().removeDuplicates()
            .sink { [weak self] hide in self?.applyDockIcon(hide: hide) }
            .store(in: &cancellables)

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.renderStatusItem() }
            .store(in: &cancellables)

        settings.$interval.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.store.startPolling() }
            .store(in: &cancellables)

        renderStatusItem()
        store.startPolling()

        if settings.mainWindowVisible {
            mainWindow.show()
        }
        if settings.token.isEmpty && !settings.endpoint.contains("token=") {
            showSettings()
        }
    }

    // MARK: - App 生命周期

    /// 点 Dock 图标 / 再次打开 App：显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// 关掉主窗口不退出，菜单栏照常工作
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func applyDockIcon(hide: Bool) {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        // 切换策略后窗口可能被收到后面，重新把设置窗口拿到前面
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showMainWindow() {
        panel.close()
        store.refreshIfStale()
        mainWindow.show()
    }

    @objc private func toggleAlwaysOnTop() {
        settings.alwaysOnTop.toggle()
    }

    /// 首次安装时可用 `--set-token XXX` 把 token 写进钥匙串（由 App 自己写，之后读取不会弹授权框）
    private func handleArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--set-token"), i + 1 < args.count {
            settings.setToken(args[i + 1])
        }
        if let i = args.firstIndex(of: "--set-endpoint"), i + 1 < args.count {
            settings.endpoint = args[i + 1]
        }
    }

    // MARK: - 菜单栏

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let sections = store.sections
        let groups = MenuBarIcon.groups(windows: store.windows, sections: sections, pinned: settings.pinned)
        // 只在完全没有数据时变淡；某家临时失败沿用旧数据，不做视觉区分
        let dimmed = !store.hasData
        let empty: MenuBarIcon.EmptyState =
            store.errorMessage != nil ? .error : (store.hasData ? .idle : .loading)
        button.image = MenuBarIcon.image(groups: groups, dimmed: dimmed, emptyState: empty)
        button.toolTip = tooltip(groups: groups)
    }

    private func tooltip(groups: [MenuBarIcon.Group]) -> String {
        if let err = store.errorMessage, !store.hasData { return "Tidy Usage · \(err)" }
        let titles = Dictionary(uniqueKeysWithValues: store.sections.flatMap(\.rows).map { ($0.id, $0.title) })
        let lines = groups.map { g in
            ProviderInfo.title(g.provider) + "  " + g.windows.map { w in
                "\(titles[w.id] ?? w.name) \(Int(w.used.rounded()))%"
            }.joined(separator: " · ")
        }
        return lines.isEmpty ? "Tidy Usage" : lines.joined(separator: "\n")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // 连点防抖：面板开合动画约 0.12s
        guard Throttle.allow("statusItem", interval: 0.25) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if panel.isShown {
            panel.close()
        } else {
            store.refreshIfStale()
            panel.show(relativeTo: sender)
            sender.highlight(true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "").target = self
        let onTop = menu.addItem(withTitle: "固定在最前面", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = settings.alwaysOnTop ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Tidy Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        guard Throttle.allow("refresh", interval: 1) else { return }
        Task { await store.refresh() }
    }
    @objc private func openSettingsAction() { showSettings() }

    /// 屏幕顶部的 App 菜单：应用 / 编辑 / 窗口。
    /// 代码式 App 没有默认菜单，不建的话 ⌘C/⌘V/⌘Q 等快捷键无人响应。
    private func installMainMenu() {
        let main = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Tidy Usage")
        appMenu.addItem(withTitle: "关于 Tidy Usage",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Tidy Usage", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Tidy Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // 窗口菜单
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.delegate = self
        windowMenu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "0").target = self
        let onTop = windowMenu.addItem(withTitle: "固定在最前面", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        onTop.keyEquivalentModifierMask = [.command, .option]
        onTop.target = self
        onTop.tag = MenuTag.alwaysOnTop
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private enum MenuTag { static let alwaysOnTop = 1001 }

    // MARK: - 设置窗口

    private func showSettings() {
        panel.close()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, store: store))
            let window = NSWindow(contentViewController: host)
            window.title = "Tidy Usage 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // 主窗口置顶时，设置窗口也要同层，否则会被压在下面
        settingsWindow?.level = settings.alwaysOnTop ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 打开「窗口」菜单时同步「固定在最前面」的勾选状态
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MenuTag.alwaysOnTop)?.state = settings.alwaysOnTop ? .on : .off
    }
}
