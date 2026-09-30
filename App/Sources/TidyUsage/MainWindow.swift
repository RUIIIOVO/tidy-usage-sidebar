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
        if !settings.showMainWindow {
            settings.showMainWindow = true
        }
    }

    func close() {
        window.orderOut(nil)
        if settings.showMainWindow {
            settings.showMainWindow = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 仅用户主动点击关闭按钮或按 ⌘W 时触发，将状态标记为关闭；
        // App 退出时不走该方法，下次启动可正确恢复上次的窗口显示与位置
        if settings.showMainWindow {
            settings.showMainWindow = false
        }
        return true
    }

    func windowDidMove(_ notification: Notification) {
        window.saveFrame(usingName: Self.autosaveName)
    }

    func saveFrame() {
        window.saveFrame(usingName: Self.autosaveName)
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

    /// 按内容高度调整窗口，保持顶边不动。
    /// fullSizeContentView 模式下 NSHostingView.fittingSize 会附加上安全区高度（约 32pt），
    /// 但 SwiftUI 内容已设 .ignoresSafeArea() 从窗口顶端开始排，因此需扣除该 safeArea 避免底部留白。
    private func relayout() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let safeTop = window.contentView?.safeAreaInsets.top ?? 0
        let targetHeight = max(100, (size.height - safeTop).rounded())
        let old = window.frame
        let frame = NSRect(x: old.minX, y: old.maxY - targetHeight, width: size.width, height: targetHeight)
        if frame != old {
            window.setFrame(frame, display: true)
            window.saveFrame(usingName: Self.autosaveName)
        }
    }

    /// 首次打开：放在主屏右上角
    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let vis = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vis.maxX - size.width - Self.margin,
                                      y: vis.maxY - size.height - Self.margin))
    }

    /// 标题栏区域至少有一块在某个屏幕内才算可见，否则挪回主屏。
    /// 并在屏幕内做边界吸附，防止标题栏被顶到系统菜单栏下面。
    private func ensureOnScreen() {
        let f = window.frame
        let titleStrip = NSRect(x: f.minX, y: f.maxY - 28, width: f.width, height: 28)
        guard let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersection(titleStrip).width >= 60
        }) else {
            placeDefault()
            return
        }
        let vis = screen.visibleFrame
        var newX = f.minX
        var newY = f.minY
        if f.maxY > vis.maxY { newY = vis.maxY - f.height }
        if newY < vis.minY { newY = vis.minY }
        if f.maxX > vis.maxX { newX = vis.maxX - f.width }
        if f.minX < vis.minX { newX = vis.minX }
        if newX != f.minX || newY != f.minY {
            window.setFrameOrigin(NSPoint(x: newX, y: newY))
            window.saveFrame(usingName: Self.autosaveName)
        }
    }
}
