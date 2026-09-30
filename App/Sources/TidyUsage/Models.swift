import AppKit
import SwiftUI

// MARK: - 接口原始结构（server/usage_api.py 的 /usage 返回）

struct UsageResponse: Decodable {
    let ok: Bool?
    let email: String?
    let emails: [String: String?]?
    let windows: [RawWindow]?
    let stale: Bool?
    let error: String?
    /// 各服务商单独的失败原因（如 claude: anthropic HTTP 429）
    let errors: [String: String]?
    let queried_at: Double?
}

struct RawWindow: Codable {
    let provider: String?
    let name: String
    let label: String?
    let utilization: Double
    let resets_at: String?
    // DeepSeek 余额
    let balance: Double?
    let currency: String?

    init(provider: String?, name: String, label: String?, utilization: Double,
         resets_at: String?, balance: Double? = nil, currency: String? = nil) {
        self.provider = provider; self.name = name; self.label = label
        self.utilization = utilization; self.resets_at = resets_at
        self.balance = balance; self.currency = currency
    }
}

// MARK: - 领域模型

/// 一个额度窗口。`used` 是已用百分比（0–100）。
struct UsageWindow: Identifiable, Hashable {
    enum Kind { case session, week, balance }

    let id: String
    let provider: String
    let name: String
    let label: String?
    let used: Double          // 已用百分比（balance 类型时为 0）
    let resetsAt: Date?
    let balance: Double?      // 余额（仅 balance 类型）
    let currency: String?     // 货币（仅 balance 类型）

    var kind: Kind {
        if name == "balance" { return .balance }
        let n = name.lowercased()
        return (n == "five_hour" || n == "5h" || n.contains("hour")) ? .session : .week
    }

    /// 环里印的字：5 = 5 小时，7 = 7 天；分模型的周额度用模型名首字母（Fable → F）
    var glyph: String {
        if kind == .session { return "5" }
        if provider == "claude", name != "seven_day", let first = scopedName?.first {
            return String(first).uppercased()
        }
        return "7"
    }

    /// Claude 分模型周额度的模型名（Fable / Opus / Sonnet）
    var scopedName: String? {
        switch name {
        case "seven_day_opus": return "Opus"
        case "seven_day_sonnet": return "Sonnet"
        case "weekly_scoped": return label
        default: return name == "seven_day" ? nil : label
        }
    }

    var level: UsageLevel {
        if kind == .balance { return BalanceLevel.level(balance ?? 0) }
        return UsageLevel(used: used)
    }

    /// 还原成接口结构，用于落盘缓存
    var raw: RawWindow {
        RawWindow(provider: provider, name: name, label: label, utilization: used,
                  resets_at: resetsAt.map { DateParsing.format($0) },
                  balance: balance, currency: currency)
    }

    init(raw: RawWindow) {
        let provider = raw.provider ?? "claude"
        self.provider = provider
        self.name = raw.name
        self.label = raw.label
        self.used = max(0, min(100, raw.utilization))
        self.resetsAt = raw.resets_at.flatMap(DateParsing.parse)
        self.balance = raw.balance
        self.currency = raw.currency
        self.id = UsageWindow.makeID(provider: provider, label: raw.label, name: raw.name)
    }

    static func makeID(provider: String, label: String?, name: String) -> String {
        "\(provider)|\(label ?? "")|\(name)"
    }
}

enum UsageLevel {
    case normal, warning, critical

    init(used: Double) {
        if used >= 90 { self = .critical }
        else if used >= 80 { self = .warning }
        else { self = .normal }
    }

    var nsColor: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var color: Color? { nsColor.map { Color(nsColor: $0) } }
}

/// DeepSeek 余额预警等级：< ¥5 橙色，< ¥1 红色
enum BalanceLevel {
    static func level(_ balance: Double) -> UsageLevel {
        if balance < 1 { return .critical }
        if balance < 5 { return .warning }
        return .normal
    }
}

// MARK: - 面板分组

struct DisplayRow: Identifiable {
    let window: UsageWindow
    let title: String
    var id: String { window.id }
}

struct RowGroup: Identifiable {
    let id: String
    let title: String?
    let rows: [DisplayRow]
}

struct ProviderSection: Identifiable {
    let id: String
    let title: String
    let email: String?
    let groups: [RowGroup]
    /// 本次没拿到，显示的是这个时间点的旧数据
    var staleSince: Date? = nil

    var rows: [DisplayRow] { groups.flatMap(\.rows) }
}

enum Sections {
    static let providerOrder = ["claude", "antigravity", "deepseek"]

    static func build(windows: [UsageWindow], emails: [String: String],
                      staleSince: [String: Date] = [:]) -> [ProviderSection] {
        var providers: [String] = []
        for w in windows where !providers.contains(w.provider) { providers.append(w.provider) }
        providers.sort { rank($0) < rank($1) }

        return providers.map { p in
            let list = windows.filter { $0.provider == p }
            let groups: [RowGroup]
            if p == "claude" {
                // Claude：一组，label（如 Fable）并入行标题
                let rows = list.sorted { claudeRank($0) < claudeRank($1) }
                    .map { DisplayRow(window: $0, title: claudeTitle($0)) }
                groups = [RowGroup(id: p, title: nil, rows: rows)]
            } else if p == "deepseek" {
                // DeepSeek：单行余额
                let rows = list.map { DisplayRow(window: $0, title: Titles.balance) }
                groups = [RowGroup(id: p, title: nil, rows: rows)]
            } else {
                // 其它（Antigravity）：按 label 分小组
                var labels: [String] = []
                for w in list where !labels.contains(w.label ?? "") { labels.append(w.label ?? "") }
                groups = labels.map { label in
                    let rows = list.filter { ($0.label ?? "") == label }
                        .sorted { ($0.kind == .session ? 0 : 1) < ($1.kind == .session ? 0 : 1) }
                        .map { DisplayRow(window: $0, title: $0.kind == .session ? Titles.session : Titles.week) }
                    return RowGroup(id: "\(p)|\(label)", title: label.isEmpty ? nil : label, rows: rows)
                }
            }
            return ProviderSection(id: p, title: ProviderInfo.title(p), email: emails[p], groups: groups,
                                   staleSince: staleSince[p])
        }
    }

    private static func rank(_ p: String) -> Int {
        providerOrder.firstIndex(of: p) ?? providerOrder.count
    }

    private static func claudeRank(_ w: UsageWindow) -> Int {
        switch w.name {
        case "five_hour": return 0
        case "seven_day": return 1
        default: return 2
        }
    }

    private static func claudeTitle(_ w: UsageWindow) -> String {
        if w.kind == .session { return Titles.session }
        if let model = w.scopedName { return "\(Titles.week) · \(model)" }
        return Titles.week
    }
}

/// 统一的窗口名称
enum Titles {
    static let session = "5 小时"
    static let week = "本周"
    static let balance = "余额"
}

// MARK: - 服务商外观

enum ProviderInfo {
    struct Logo {
        let path: CGPath
        let evenOdd: Bool
        let brand: Color?

        init(path: CGPath, evenOdd: Bool, brand: Color?) {
            self.path = Logo.normalized(path)
            self.evenOdd = evenOdd
            self.brand = brand
        }

        /// 各家 SVG 的留白差异很大（DeepSeek 鲸鱼只有 17.8 高，Claude 是 24），
        /// 若统一按 24 的 viewBox 缩放，鲸鱼会显得小一圈。
        /// 这里把每家的视觉包围盒等比归一化：高度对齐到同一个值，
        /// 宽度超过上限时再按宽度回缩，最后居中到 24×24 画布。
        /// 后续绘制代码仍按 /24 缩放即可，无需知道这层差异。
        private static func normalized(_ p: CGPath) -> CGPath {
            let b = p.boundingBox
            guard b.width > 0, b.height > 0 else { return p }
            let targetHeight: CGFloat = 24 * 0.9      // 统一视觉高度
            let maxWidth: CGFloat = 24 * 1.12         // 扁宽图形（鲸鱼）的宽度上限
            var scale = targetHeight / b.height
            if b.width * scale > maxWidth { scale = maxWidth / b.width }
            let cx = b.minX + b.width / 2, cy = b.minY + b.height / 2
            var t = CGAffineTransform(translationX: 12 - cx * scale, y: 12 - cy * scale)
                .scaledBy(x: scale, y: scale)
            return p.copy(using: &t) ?? p
        }
    }

    private static let claudeLogo = Logo(
        path: SVGPath.parse(LogoPaths.claude), evenOdd: false,
        brand: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
    private static let antigravityLogo = Logo(
        path: SVGPath.parse(LogoPaths.antigravity), evenOdd: true, brand: nil)
    private static let deepseekLogo = Logo(
        path: SVGPath.parse(LogoPaths.deepseek), evenOdd: false,
        brand: Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255))

    static func title(_ p: String) -> String {
        switch p {
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        case "deepseek": return "DeepSeek"
        default: return p.prefix(1).uppercased() + p.dropFirst()
        }
    }

    static func logo(_ p: String) -> Logo? {
        switch p {
        case "claude": return claudeLogo
        case "antigravity": return antigravityLogo
        case "deepseek": return deepseekLogo
        default: return nil
        }
    }
}

// MARK: - 时间

enum DateParsing {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 兼容 "2026-09-30T03:00:00.040439+00:00" 和 "2026-10-05T01:31:05Z"
    static func format(_ d: Date) -> String { formatter.string(from: d) }

    static func parse(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}

enum ResetText {
    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 24 小时内显示倒计时（2 小时 6 分后重置），更远的显示具体时间（10月2日 10:00 重置）
    static func text(for w: UsageWindow, now: Date) -> String {
        guard let date = w.resetsAt, w.used > 0 else { return "未开始计时" }
        let mins = Int((date.timeIntervalSince(now) / 60).rounded())
        if mins <= 0 { return "即将重置" }
        if mins < 60 { return "\(mins) 分钟后重置" }
        let h = mins / 60, m = mins % 60
        if h < 24 { return m > 0 ? "\(h) 小时 \(m) 分后重置" : "\(h) 小时后重置" }
        return "\(absolute.string(from: date)) 重置"
    }
}

/// 数据新鲜度的措辞。近期用相对时间（一眼看出新鲜度），跨天用绝对时间点
/// （「23 小时前」远不如「昨天 15:35」好读）。
enum UpdateText {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 刚刚 / 12 分钟前 / 5 小时前 / 昨天 15:35 / 9月28日 15:35
    static func age(since date: Date, now: Date) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600)) 小时前" }
        if cal.isDateInYesterday(date) { return "昨天 \(clock.string(from: date))" }
        return dayClock.string(from: date)
    }

    /// 「……的数据」里的定语形式：刚才的 / 12 分钟前的 / 昨天 15:35 的
    static func attributive(since date: Date, now: Date) -> String {
        let a = age(since: date, now: now)
        return a == "刚刚" ? "刚才的" : joined(a, "的")
    }

    /// 中文与数字之间补一个空格（仅数字开头时补，如「 12 分钟前」）
    static func spaced(_ s: String) -> String {
        guard let f = s.first, f.isASCII, f.isNumber else { return s }
        return " " + s
    }

    /// 拼接时前段以数字结尾就补空格，避开「15:43更新」
    static func joined(_ a: String, _ b: String) -> String {
        guard let l = a.last, l.isASCII, l.isNumber else { return a + b }
        return a + " " + b
    }
}
