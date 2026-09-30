import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    @State private var endpoint = ""
    @State private var token = ""
    @State private var deepseekKey = ""
    @State private var testing = false
    @State private var saveNotice: String?
    @State private var results: [TestLine] = []
    @State private var launchAtLogin = false

    private struct TestLine: Identifiable {
        let id = UUID()
        let ok: Bool
        let text: String
    }

    private let intervals: [(String, Double)] = [("30 秒", 30), ("1 分钟", 60), ("2 分钟", 120), ("5 分钟", 300)]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("额度数据源") {
                    TextField("接口地址", text: $endpoint, prompt: Text("http://your-server:8318/usage"))
                    SecureField("Token", text: $token)
                }

                Section("DeepSeek 余额") {
                    SecureField("API Key", text: $deepseekKey, prompt: Text("sk-..."))
                }

                Section("桌面主窗口") {
                    Toggle("显示桌面主窗口", isOn: $settings.showMainWindow)
                    Toggle("固定在所有窗口最前面", isOn: $settings.alwaysOnTop)
                        .disabled(!settings.showMainWindow)
                }

                Section("系统与菜单栏") {
                    Toggle("隐藏 Dock 图标（纯菜单栏模式）", isOn: $settings.hideDockIcon)
                        .help("隐藏后只保留菜单栏图标；再次打开 App 或在状态栏菜单中仍可打开主窗口")
                    Toggle("登录时启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                    Picker("刷新间隔", selection: $settings.interval) {
                        ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            // 统一的操作栏：左侧结果反馈，右侧独立「测试」与「保存」按钮
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if let notice = saveNotice {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text(notice).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                    ForEach(results) { line in
                        HStack(spacing: 5) {
                            Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(line.ok ? Color.green : Color.orange)
                            Text(line.text).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .font(.system(size: 12))
                    }
                }
                Spacer(minLength: 8)
                if testing { ProgressView().controlSize(.small) }
                Button("测试") { testConnection() }
                    .disabled(testing)
                Button("保存") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(testing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            endpoint = settings.endpoint
            token = settings.token
            deepseekKey = settings.deepseekKey
            launchAtLogin = settings.launchAtLogin
        }
    }

    private func testConnection() {
        guard !testing, Throttle.allow("testConnection", interval: 0.5) else { return }
        let ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let tk = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds = deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        results = []
        saveNotice = nil

        Task {
            var lines: [TestLine] = []

            // 测试额度数据源
            if ep.isEmpty {
                lines.append(TestLine(ok: false, text: "额度数据源：还没有填写接口地址"))
            } else {
                do {
                    let resp = try await UsageClient.fetch(endpoint: ep, token: tk)
                    let count = resp.windows?.filter { $0.provider != "deepseek" }.count ?? 0
                    lines.append(TestLine(ok: true, text: "额度数据源：连接成功，\(count) 个额度窗口"))
                } catch {
                    lines.append(TestLine(ok: false, text: "额度数据源：\(error.localizedDescription)"))
                }
            }

            // 测试 DeepSeek
            if !ds.isEmpty {
                do {
                    let raw = try await UsageClient.fetchDeepSeekBalance(apiKey: ds)
                    lines.append(TestLine(ok: true, text: String(format: "DeepSeek：连接成功，余额 ¥%.2f", raw.balance ?? 0)))
                } catch {
                    lines.append(TestLine(ok: false, text: "DeepSeek：\(error.localizedDescription)"))
                }
            }

            testing = false
            results = lines
        }
    }

    private func saveSettings() {
        guard Throttle.allow("saveSettings", interval: 0.5) else { return }
        settings.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setToken(token)
        settings.setDeepseekKey(deepseekKey)
        results = []
        saveNotice = "已保存配置并刷新数据"
        Task {
            await store.refresh()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if saveNotice == "已保存配置并刷新数据" {
                saveNotice = nil
            }
        }
    }
}
