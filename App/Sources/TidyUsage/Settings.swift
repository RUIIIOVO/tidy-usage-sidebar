import Foundation
import Security
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    /// 没有内置默认服务地址，首次启动在设置里填写
    static let defaultEndpoint = ""
    static let defaultInterval: Double = 60
    static let defaultPinned = [
        UsageWindow.makeID(provider: "claude", label: nil, name: "five_hour"),
        UsageWindow.makeID(provider: "claude", label: nil, name: "seven_day"),
        UsageWindow.makeID(provider: "antigravity", label: "Gemini Models", name: "5h"),
        UsageWindow.makeID(provider: "antigravity", label: "Gemini Models", name: "weekly"),
        UsageWindow.makeID(provider: "deepseek", label: nil, name: "balance"),
    ]

    private let defaults = UserDefaults.standard

    @Published var endpoint: String {
        didSet { defaults.set(endpoint, forKey: "endpoint") }
    }
    @Published var interval: Double {
        didSet { defaults.set(interval, forKey: "interval") }
    }
    /// 显示在菜单栏的窗口 ID
    @Published var pinned: [String] {
        didSet { defaults.set(pinned, forKey: "pinned") }
    }
    @Published private(set) var token: String
    @Published private(set) var deepseekKey: String

    init() {
        endpoint = defaults.string(forKey: "endpoint") ?? Self.defaultEndpoint
        let iv = defaults.double(forKey: "interval")
        interval = iv > 0 ? iv : Self.defaultInterval
        pinned = defaults.stringArray(forKey: "pinned") ?? Self.defaultPinned
        token = Keychain.read() ?? ""
        deepseekKey = Keychain.read(account: "deepseek_key") ?? ""
    }

    func setToken(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { Keychain.delete() } else { Keychain.write(v) }
        token = v
    }

    func setDeepseekKey(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { Keychain.delete(account: "deepseek_key") } else { Keychain.write(v, account: "deepseek_key") }
        deepseekKey = v
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func togglePin(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else { pinned.append(id) }
    }

    func resetPinned() { pinned = Self.defaultPinned }

    // MARK: 登录时启动

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("TidyUsage: launch-at-login toggle failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}

/// Token 存在登录钥匙串里，不落盘到 UserDefaults。
enum Keychain {
    static let service = "io.github.tidy-usage-sidebar"

    private static func baseQuery(account: String = "token") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String = "token") -> String? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String = "token") {
        let data = Data(value.utf8)
        let q = baseQuery(account: account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q2 = q
            q2[kSecValueData as String] = data
            SecItemAdd(q2 as CFDictionary, nil)
        }
    }

    static func delete(account: String = "token") {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
