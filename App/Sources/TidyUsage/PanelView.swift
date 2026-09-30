import AppKit
import SwiftUI

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
                        if index > 0 { Divider().opacity(0.6).padding(.horizontal, 6) }
                        SectionView(section: section, settings: settings, now: timeline.date)
                    }
                } else {
                    EmptyStateView(store: store, openSettings: openSettings)
                }
                Divider().opacity(0.6).padding(.horizontal, 6)
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
                    LogoShape(logo: logo)
                        .fill(logo.brand ?? .primary, style: FillStyle(eoFill: logo.evenOdd))
                        .frame(width: 14, height: 14)
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
                        .font(.system(size: 10.5, weight: .medium))
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

    /// 标题列固定宽度，保证每行的重置时间从同一条竖线开始
    static let titleWidth: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .frame(width: Self.titleWidth, alignment: .leading)
                Text(ResetText.text(for: w, now: now))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(w.used.rounded()))")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                    Text("%")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressBar(fraction: w.used / 100, color: accent)
        }
        // 未显示在菜单栏的行整体变淡；悬停时稍微提亮，提示可点击
        .opacity(pinned ? 1 : (hovering ? 0.7 : 0.45))
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        // 整行都可点击：切换是否显示在菜单栏
        .contentShape(Rectangle())
        .onTapGesture(perform: togglePin)
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
        .frame(height: 4)
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
                Text("正在获取额度…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(store.errorMessage ?? "暂无数据")
                    .font(.system(size: 12))
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

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var status: (Color, String) {
        let time = store.dataTime.map { Self.timeFormat.string(from: $0) }
        if let err = store.errorMessage {
            if let time { return (.orange, "更新失败 · 显示 \(time) 的数据") }
            return (.red, err)
        }
        if store.serverStale, let time { return (.yellow, "缓存数据 · \(time)") }
        if let time { return (.green, "\(time) 更新") }
        return (.secondary, "等待数据")
    }

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(status.0.opacity(0.85)).frame(width: 5, height: 5)
                Text(status.1).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help(store.errorMessage ?? "")
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: store.isLoading)
            }
            .buttonStyle(IconButtonStyle())
            .help("刷新")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("设置")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("退出 Tidy Usage")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 9)
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
