import AppKit

/// 菜单栏图像：[logo] (5) (7)   [logo] (5) (7)
/// 非模板图（否则系统会抹掉橙/红告警色）。常态颜色在绘制时按菜单栏外观取黑或白。
enum MenuBarIcon {
    struct Group {
        let provider: String
        let windows: [UsageWindow]
        /// 这家本次拿到的是旧数据 → 这一组画淡
        var stale = false
    }

    // 尺寸对齐系统菜单栏图标（Wi-Fi / 控制中心等内容高 12.5–16pt）
    static let height: CGFloat = 22
    static let ringSize: CGFloat = 16
    static let logoSize: CGFloat = 15
    // 间距层级：环↔环 3 < logo↔环 5 < 组↔组 12 < 系统图标间 ~20
    static let ringGap: CGFloat = 3
    static let logoGap: CGFloat = 5
    static let groupGap: CGFloat = 12

    static func groups(windows: [UsageWindow], sections: [ProviderSection], pinned: [String]) -> [Group] {
        sections.compactMap { section in
            let ws = section.rows.map(\.window).filter { pinned.contains($0.id) }
            return ws.isEmpty ? nil : Group(provider: section.id, windows: ws, stale: section.staleSince != nil)
        }
    }

    /// dimmed：数据过期或请求失败时整体降低不透明度
    enum EmptyState { case idle, loading, error }

    static func image(groups: [Group], dimmed: Bool, emptyState: EmptyState = .idle) -> NSImage {
        if groups.isEmpty { return placeholder(emptyState) }

        var width: CGFloat = 0
        for (i, g) in groups.enumerated() {
            if i > 0 { width += groupGap }
            width += logoSize + logoGap
            width += CGFloat(g.windows.count) * ringSize + CGFloat(g.windows.count - 1) * ringGap
        }
        width = ceil(width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base = baseColor()
            ctx.setAlpha(dimmed ? 0.45 : 1)
            var x: CGFloat = 0
            for (i, g) in groups.enumerated() {
                if i > 0 { x += groupGap }
                ctx.setAlpha(dimmed || g.stale ? 0.45 : 1)
                if let logo = ProviderInfo.logo(g.provider) {
                    drawLogo(logo, in: CGRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize),
                             color: base, ctx: ctx)
                }
                x += logoSize + logoGap
                for (j, w) in g.windows.enumerated() {
                    if j > 0 { x += ringGap }
                    let rect = CGRect(x: x, y: (height - ringSize) / 2, width: ringSize, height: ringSize)
                    drawRing(used: w.used, glyph: w.glyph, color: w.level.nsColor ?? base, in: rect, ctx: ctx)
                    x += ringSize
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 空状态：SF Symbol gauge.with.needle（模板图，系统自动适配深浅与高亮）
    /// - idle：有数据但没钉任何环
    /// - loading：还没拿到数据 → 淡
    /// - error：请求失败 → 右上角橙点（此时需非模板图才能保留橙色）
    private static func placeholder(_ state: EmptyState) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Tidy Usage")?
            .withSymbolConfiguration(cfg) else { return NSImage() }

        if state == .idle {
            symbol.isTemplate = true
            return symbol
        }

        let sz = symbol.size
        let badge: CGFloat = 5.5
        let width = ceil(sz.width + (state == .error ? 2 : 0))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let base = baseColor().withAlphaComponent(state == .loading ? 0.45 : 1)
            let rect = NSRect(x: 0, y: (height - sz.height) / 2, width: sz.width, height: sz.height)
            // 先画符号再用前景色 sourceAtop 着色
            let tinted = NSImage(size: sz, flipped: false) { r in
                symbol.draw(in: r)
                base.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            if state == .error {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: width - badge, y: rect.maxY - badge + 0.5,
                                            width: badge, height: badge)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 按当前绘制外观（即菜单栏外观）取前景色
    private static func baseColor() -> NSColor {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }

    // MARK: - 绘制原语（面板里的小环也复用）

    static func drawRing(used: Double, glyph: String, color: NSColor, in rect: CGRect, ctx: CGContext) {
        let lineWidth: CGFloat = rect.width >= 16 ? 1.7 : 1.5
        let r = rect.width / 2 - lineWidth / 2 - 0.2
        let center = CGPoint(x: rect.midX, y: rect.midY)

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        ctx.setStrokeColor(color.withAlphaComponent(color.alphaComponent * 0.26).cgColor)
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.strokePath()

        let frac = max(0, min(1, used / 100))
        if frac > 0.004 {
            // flipped 坐标：从 12 点方向顺时针
            let start = -CGFloat.pi / 2
            let end = start + 2 * .pi * CGFloat(frac)
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()

        let fontSize = rect.width * 0.5
        var font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: fontSize) { font = f }
        let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    static func drawLogo(_ logo: ProviderInfo.Logo, in rect: CGRect, color: NSColor, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 24, y: rect.height / 24)
        ctx.addPath(logo.path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath(using: logo.evenOdd ? .evenOdd : .winding)
        ctx.restoreGState()
    }
}
