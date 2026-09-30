import AppKit
import Combine
import SwiftUI

/// 主窗口：点 App 图标打开的常驻窗口，内容与菜单栏面板相同。
/// - 可拖到任意屏幕，位置自动记忆
/// - 可固定在所有窗口最前面
/// - 高度随内容变化，顶边不动
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private let settings: AppSettings
    private var sizeObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

    private static let autosaveName = "TidyUsageMainWindow"
    private static let margin: CGFloat = 16

    var isShown: Bool { window.isVisible }

    init<Content: View>(rootView: Content, settings: AppSettings) {
        self.settings = settings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Tidy Usage"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.tabbingMode = .disallowed

        hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = .intrinsicContentSize

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        // 窗口失焦时也保持毛玻璃，不变灰
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
        super.init()
        window.delegate = self

        relayout()
        if !window.setFrameUsingName(Self.autosaveName) {
            placeDefault()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        relayout()

        sizeObservation = hosting.observe(\.fittingSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.relayout() }
        }

        settings.$alwaysOnTop
            .sink { [weak self] on in self?.applyLevel(on) }
            .store(in: &cancellables)

        // 拔掉副屏 / 改分辨率后，窗口若落到屏幕外就拉回来
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureOnScreen() }
        }
    }

    // MARK: - 显示 / 关闭

    func show() {
        ensureOnScreen()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settings.mainWindowVisible = true
    }

    func close() {
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 仅用户主动关闭时记下；退出 App 不走这里，下次启动会恢复窗口
        settings.mainWindowVisible = false
    }

    // MARK: - 置顶

    private func applyLevel(_ onTop: Bool) {
        window.level = onTop ? .floating : .normal
        // 置顶时跟随所有桌面，并能浮在全屏 App 上方
        window.collectionBehavior = onTop
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .participatesInCycle]
    }

    // MARK: - 布局

    /// 按内容高度调整窗口，保持顶边不动
    private func relayout() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let old = window.frame
        let frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        if frame != old { window.setFrame(frame, display: true) }
    }

    /// 首次打开：放在主屏右上角
    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let vis = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vis.maxX - size.width - Self.margin,
                                      y: vis.maxY - size.height - Self.margin))
    }

    /// 标题栏区域至少有一块在某个屏幕内才算可见，否则挪回主屏
    private func ensureOnScreen() {
        let f = window.frame
        let titleStrip = NSRect(x: f.minX, y: f.maxY - 28, width: f.width, height: 28)
        let visible = NSScreen.screens.contains { screen in
            let hit = screen.visibleFrame.intersection(titleStrip)
            return hit.width >= 60 && hit.height >= 10
        }
        if !visible { placeDefault() }
    }
}
