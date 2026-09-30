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

struct RawWindow: Decodable {
    let provider: String?
    let name: String
    let label: String?
    let utilization: Double
    let resets_at: String?
}

// MARK: - 领域模型

/// 一个额度窗口。`used` 是已用百分比（0–100）。
struct UsageWindow: Identifiable, Hashable {
    enum Kind { case session, week }

    let id: String
    let provider: String
    let name: String
    let label: String?
    let used: Double
    let resetsAt: Date?

    var kind: Kind {
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

    var level: UsageLevel { UsageLevel(used: used) }

    init(raw: RawWindow) {
        let provider = raw.provider ?? "claude"
        self.provider = provider
        self.name = raw.name
        self.label = raw.label
        self.used = max(0, min(100, raw.utilization))
        self.resetsAt = raw.resets_at.flatMap(DateParsing.parse)
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
    static let providerOrder = ["claude", "antigravity"]

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
}

// MARK: - 服务商外观

enum ProviderInfo {
    struct Logo {
        let path: CGPath
        let evenOdd: Bool
        let brand: Color?
    }

    private static let claudeLogo = Logo(
        path: SVGPath.parse(LogoPaths.claude), evenOdd: false,
        brand: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
    private static let antigravityLogo = Logo(
        path: SVGPath.parse(LogoPaths.antigravity), evenOdd: true, brand: nil)

    static func title(_ p: String) -> String {
        switch p {
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        default: return p.prefix(1).uppercased() + p.dropFirst()
        }
    }

    static func logo(_ p: String) -> Logo? {
        switch p {
        case "claude": return claudeLogo
        case "antigravity": return antigravityLogo
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
