import Foundation

/// 简单的点击节流：同一个 key 在 interval 内只放行第一次
@MainActor
enum Throttle {
    private static var last: [String: Date] = [:]

    static func allow(_ key: String, interval: TimeInterval = 0.35) -> Bool {
        let now = Date()
        if let t = last[key], now.timeIntervalSince(t) < interval { return false }
        last[key] = now
        return true
    }
}
