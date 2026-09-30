import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    @State private var endpoint = ""
    @State private var token = ""
    @State private var deepseekKey = ""
    @State private var testing = false
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

                Section("行为") {
                    Picker("刷新间隔", selection: $settings.interval) {
                        ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Toggle("登录时启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            // 统一的操作栏：一次保存并测试全部连接
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
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
                Button("保存并测试") { saveAndTest() }
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

    private func saveAndTest() {
        guard !testing, Throttle.allow("saveAndTest", interval: 1) else { return }
        settings.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setToken(token)
        settings.setDeepseekKey(deepseekKey)
        testing = true
        results = []
        Task {
            await store.refresh()
            testing = false

            var lines: [TestLine] = []
            let usageCount = store.windows.filter { $0.provider != "deepseek" }.count
            if settings.endpoint.isEmpty {
                lines.append(TestLine(ok: false, text: "额度数据源：还没有填写接口地址"))
            } else if let err = store.errorMessage, usageCount == 0 {
                lines.append(TestLine(ok: false, text: "额度数据源：\(err)"))
            } else {
                lines.append(TestLine(ok: true, text: "额度数据源：已连接，\(usageCount) 个额度窗口"))
            }

            if !settings.deepseekKey.isEmpty {
                if let err = store.deepseekError {
                    lines.append(TestLine(ok: false, text: "DeepSeek：\(err)"))
                } else if let b = store.windows.first(where: { $0.provider == "deepseek" })?.balance {
                    lines.append(TestLine(ok: true, text: String(format: "DeepSeek：已连接，余额 ¥%.2f", b)))
                }
            }
            results = lines
        }
    }
}
