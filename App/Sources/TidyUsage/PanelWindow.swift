import AppKit
import SwiftUI

/// 自绘下拉面板（替代 NSPopover）。
/// NSPopover 挂在状态栏按钮上，按钮宽度一变就会重新定位导致跳动；
/// 这里打开时算一次位置，之后菜单栏怎么变都不动。
@MainActor
final class PanelController: NSObject {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// 面板顶边中点固定在打开时的位置
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    private var sizeObservation: NSKeyValueObservation?

    private weak var anchorButton: NSStatusBarButton?

    var isShown: Bool { panel.isVisible }
    var onClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
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
        panel.contentView = effect
        super.init()

        // 内容高度变化（加载完成 / 错误态）时，保持顶边不动
        sizeObservation = hosting.observe(\.fittingSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.relayout() }
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        isShown ? close() : show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorButton = button
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(rectInWindow)
        anchorMidX = screenRect.midX
        anchorTop = screenRect.minY - 5
        relayout()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        guard isShown else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.onClose?()
            }
        })
    }

    private func relayout() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var x = (anchorMidX - size.width / 2).rounded()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchorMidX, y: anchorTop)) })
            ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
        }
        panel.setFrame(NSRect(x: x, y: anchorTop - size.height, width: size.width, height: size.height),
                       display: true)
    }

    // 点面板外 / 按 Esc 关闭
    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                // 点状态栏图标本身交给按钮的 toggle 处理，避免"先关再开"
                if let b = self.anchorButton, let w = b.window,
                   w.convertToScreen(b.convert(b.bounds, to: nil)).contains(point) { return }
                self.close()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        clickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
    }
}
