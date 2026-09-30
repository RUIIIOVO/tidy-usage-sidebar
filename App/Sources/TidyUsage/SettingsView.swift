import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    @State private var endpoint = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var launchAtLogin = false

    private let intervals: [(String, Double)] = [("30 秒", 30), ("1 分钟", 60), ("2 分钟", 120), ("5 分钟", 300)]

    var body: some View {
        Form {
            Section("数据源") {
                TextField("接口地址", text: $endpoint, prompt: Text("http://your-server:8318/usage"))
                SecureField("Token", text: $token, prompt: Text("存放在钥匙串"))
                HStack {
                    Button("保存并测试") { saveAndTest() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
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
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            endpoint = settings.endpoint
            token = settings.token
            launchAtLogin = settings.launchAtLogin
        }
    }

    private func saveAndTest() {
        settings.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setToken(token)
        testing = true
        testResult = nil
        Task {
            await store.refresh()
            testing = false
            if let err = store.errorMessage {
                testResult = "失败：\(err)"
            } else {
                testResult = "已连接，拿到 \(store.windows.count) 个额度窗口"
            }
        }
    }
}
