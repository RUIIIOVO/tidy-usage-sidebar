import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
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

        if settings.token.isEmpty && !settings.endpoint.contains("token=") {
            showSettings()
        }
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
        let dimmed = store.errorMessage != nil || !store.hasData
        button.image = MenuBarIcon.image(groups: groups, dimmed: dimmed)
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
        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Tidy Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { Task { await store.refresh() } }
    @objc private func openSettingsAction() { showSettings() }

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
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
