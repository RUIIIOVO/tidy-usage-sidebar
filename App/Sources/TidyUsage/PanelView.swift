import AppKit
import SwiftUI

/// 行内竖直间距的单一出处。余额行没有进度条，
/// 靠这里的常量把它的说明行放到与其它行「重置时间」相同的高度。
private enum Metrics {
    static let barTopGap: CGFloat = 6
    static let barHeight: CGFloat = 4
    static let noteTopGap: CGFloat = 5
    static let rowPadding: CGFloat = 7
    /// 没有进度条时，说明行要跳过进度条占的那段高度
    static let noteTopGapWithoutBar = barTopGap + barHeight + noteTopGap
}

/// 点开菜单栏后的面板
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                if store.hasData {
                    ForEach(Array(store.sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { Spacer().frame(height: 4) }
                        SectionView(section: section, settings: settings, now: timeline.date)
                    }
                } else {
                    EmptyStateView(store: store, openSettings: openSettings)
                }
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                    .padding(.horizontal, 6).padding(.top, 2)
                FooterView(store: store, now: timeline.date, openSettings: openSettings)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
    }
}

private struct SectionView: View {
    let section: ProviderSection
    @ObservedObject var settings: AppSettings
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let logo = ProviderInfo.logo(section.id) {
                    // 固定宽度的图标列：各家宽高比不同，按最宽的一个预留，
                    // 这样图标不会溢出挤到标题，各分组的标题左边缘也保持一致
                    LogoShape(logo: logo)
                        .fill(logo.brand ?? .primary, style: FillStyle(eoFill: logo.evenOdd))
                        .frame(width: 14 * ProviderInfo.maxLogoAspect, height: 14)
                }
                Text(section.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(section.groups) { group in
                if let title = group.title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .padding(.bottom, 1)
                }
                ForEach(group.rows) { row in
                    RowView(row: row, pinned: settings.isPinned(row.id), now: now) {
                        settings.togglePin(row.id)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private struct RowView: View {
    let row: DisplayRow
    let pinned: Bool
    let now: Date
    let togglePin: () -> Void
    @State private var hovering = false

    private var w: UsageWindow { row.window }
    private var accent: Color { w.level.color ?? .primary }
    private var isBalance: Bool { w.kind == .balance }

    /// 余额行只有一个数值，缺少进度条和重置时间这两行内容，
    /// 所以用「含赠金」作为第二行——赠金会过期、充值余额不会，
    /// 这是余额唯一值得关心的额外信息，也让这行的结构与其它行一致。
    private var grantedText: String {
        String(format: "含赠金 ¥%.2f", w.granted ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isBalance {
                    // 余额：¥42.50
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\u{00A5}")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f", w.balance ?? 0))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(w.used.rounded()))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("%")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if isBalance {
                // 和重置时间同一高度，跨分组的次要文字能横向对齐
                Text(grantedText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, Metrics.noteTopGapWithoutBar)
                    .opacity(w.granted == nil ? 0 : 1)
            } else {
                ProgressBar(fraction: w.used / 100, color: accent)
                    .padding(.top, Metrics.barTopGap)
                Text(ResetText.text(for: w, now: now))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, Metrics.noteTopGap)
            }
        }
        // 未显示在菜单栏的行整体变淡；悬停时稍微提亮，提示可点击
        .opacity(pinned ? 1 : (hovering ? 0.7 : 0.45))
        .padding(.horizontal, 6)
        .padding(.vertical, Metrics.rowPadding)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        // 整行都可点击：切换是否显示在菜单栏
        .contentShape(Rectangle())
        .onTapGesture {
            guard Throttle.allow("pin|\(row.id)", interval: 0.3) else { return }
            togglePin()
        }
        .help(pinned ? "已显示在菜单栏 · 点击移除" : "点击显示在菜单栏")
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: pinned)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color)
                    .frame(width: fraction > 0 ? max(4, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: Metrics.barHeight)
    }
}

struct LogoShape: Shape {
    let logo: ProviderInfo.Logo

    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24)
        return Path(logo.path.copy(using: &t) ?? logo.path)
    }
}

private struct EmptyStateView: View {
    @ObservedObject var store: UsageStore
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if store.isLoading {
                ProgressView().controlSize(.small)
                Text("正在获取额度…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                Text(store.errorMessage ?? "暂无数据")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("打开设置", action: openSettings).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct FooterView: View {
    @ObservedObject var store: UsageStore
    let now: Date
    var openSettings: () -> Void

    private static let preciseFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 常态白点：只有异常（失败 / 缓存）才上色，保持整体单色
    private var status: (Color, String) {
        guard let date = store.dataTime else {
            if let err = store.errorMessage { return (.red, err) }
            return (.secondary, "等待数据")
        }
        let age = UpdateText.age(since: date, now: now)
        if store.errorMessage != nil {
            let attr = UpdateText.spaced(UpdateText.attributive(since: date, now: now))
            return (.orange, "更新失败 · 显示\(attr)数据")
        }
        if store.serverStale { return (.yellow, "缓存数据 · \(age)") }
        return (.primary, UpdateText.joined(age, "更新"))
    }

    /// 悬停显示精确时间，相对时间负责一眼看新鲜度，精确值负责到底是几点几分
    private var helpText: String {
        var parts: [String] = []
        if let t = store.dataTime { parts.append("最后刷新 \(Self.preciseFormat.string(from: t))") }
        if let q = store.serverQueriedAt { parts.append("服务端取数 \(Self.preciseFormat.string(from: q))") }
        if let e = store.errorMessage { parts.append(e) }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        // 三个按钮等间距；间距调大一点，让终态动作不至于贴着手边的常用按钮
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(status.0.opacity(0.85)).frame(width: 5, height: 5)
                Text(status.1).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help(helpText)
            }
            Spacer()
            RefreshButton(store: store)

            Button {
                guard Throttle.allow("settings", interval: 0.6) else { return }
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("设置")

            Button {
                guard Throttle.allow("quit", interval: 1) else { return }
                confirmQuit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("退出 Tidy Usage")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 9)
    }
}

/// 退出前二次确认
@MainActor
private func confirmQuit() {
    let alert = NSAlert()
    alert.messageText = "退出 Tidy Usage？"
    alert.informativeText = "退出后菜单栏将不再显示额度。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "退出")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        NSApp.terminate(nil)
    }
}

// MARK: - 交互样式

/// 面板底部的图标按钮：悬停出现圆角底色、图标变亮，按下加深
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointingHandCursor()
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

/// 刷新按钮：每次点击至少完整转一圈；请求没结束就一圈圈接着转，结束后停在整圈位置
private struct RefreshButton: View {
    @ObservedObject var store: UsageStore
    @State private var turns: Double = 0
    @State private var spinning = false

    private let turnDuration = 0.7

    var body: some View {
        Button(action: tap) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(turns * 360))
        }
        .buttonStyle(IconButtonStyle())
        .help("刷新")
        .onChange(of: store.isLoading) { _, loading in
            // 轮询等非点击触发的刷新也转
            if loading, !spinning { spin() }
        }
    }

    private func tap() {
        guard !spinning, !store.isLoading, Throttle.allow("refresh", interval: 1) else { return }
        spin()
        Task { await store.refresh() }
    }

    private func spin() {
        spinning = true
        withAnimation(.easeInOut(duration: turnDuration)) { turns += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + turnDuration) {
            if store.isLoading {
                spin()
            } else {
                spinning = false
            }
        }
    }
}
