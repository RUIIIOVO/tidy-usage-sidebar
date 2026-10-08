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
    private let effect: NSVisualEffectView
    private let solidView: SolidBackgroundView
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

        let container = NSView()
        container.wantsLayer = true

        let effect = NSVisualEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .popover
        effect.blendingMode = .behindWindow
        // 窗口失焦时也保持毛玻璃，不变灰
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        self.effect = effect

        let solidView = SolidBackgroundView()
        solidView.translatesAutoresizingMaskIntoConstraints = false
        self.solidView = solidView

        container.addSubview(effect)
        container.addSubview(solidView)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            solidView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            solidView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            solidView.topAnchor.constraint(equalTo: container.topAnchor),
            solidView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        super.init()
        window.delegate = self

        updateOpacity(settings.backgroundOpacity)

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

        settings.$backgroundOpacity
            .sink { [weak self] op in
                self?.updateOpacity(op)
            }
            .store(in: &cancellables)

        settings.$theme
            .sink { [weak self] _ in
                self?.solidView.needsDisplay = true
            }
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

    /// 调节不透明度：
    /// 0.2 ~ 0.7 时渐变减少毛玻璃透明度；
    /// 0.7 ~ 1.0 时平滑引入实心底色，1.0 时达到 100% 完全不透明。
    private func updateOpacity(_ op: Double) {
        let clamped = max(0.2, min(1.0, op))
        if clamped >= 0.7 {
            effect.alphaValue = 1.0
            solidView.alphaValue = CGFloat((clamped - 0.7) / 0.3)
        } else {
            effect.alphaValue = CGFloat(clamped / 0.7)
            solidView.alphaValue = 0.0
        }
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
        // 只改高度不存盘：位置由 windowDidMove / 退出时保存，这里每 30 秒随文字变化触发一次，没必要写 UserDefaults
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

/// 100% 不透明度时呈现的实心背景视图，自适应深浅色外观并带有圆角
final class SolidBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
                : NSColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        }
        color.setFill()
        path.fill()
    }
}
