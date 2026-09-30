import AppKit
import Foundation

enum UsageError: LocalizedError {
    case noToken, badURL, unauthorized, http(Int), server(String), decode

    var errorDescription: String? {
        switch self {
        case .noToken: return "还没有配置 Token"
        case .badURL: return "接口地址无效"
        case .unauthorized: return "Token 无效"
        case let .http(code): return "服务器返回 \(code)"
        case let .server(msg): return msg
        case .decode: return "返回数据无法解析"
        }
    }
}

enum UsageClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func fetch(endpoint: String, token: String) async throws -> UsageResponse {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { throw UsageError.badURL }
        let tokenInURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "token" } ?? false
        if token.isEmpty && !tokenInURL { throw UsageError.noToken }

        var req = URLRequest(url: url)
        req.setValue("tidy-usage-sidebar/1.0", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw UsageError.unauthorized }
        guard let body = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw code == 200 ? UsageError.decode : UsageError.http(code)
        }
        if body.ok != true && (body.windows ?? []).isEmpty {
            throw UsageError.server(body.error ?? "官方未返回额度窗口")
        }
        return body
    }

    // MARK: - DeepSeek 余额

    struct DeepSeekBalanceResponse: Decodable {
        let is_available: Bool?
        let balance_infos: [BalanceInfo]?
        struct BalanceInfo: Decodable {
            let currency: String
            let total_balance: String
            let granted_balance: String?
            let topped_up_balance: String?
        }
    }

    static func fetchDeepSeekBalance(apiKey: String) async throws -> RawWindow {
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("tidy-usage-sidebar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw UsageError.unauthorized }
        guard let body = try? JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data) else {
            throw code == 200 ? UsageError.decode : UsageError.http(code)
        }
        // 取第一个 CNY 余额
        guard let info = body.balance_infos?.first(where: { $0.currency == "CNY" }) ?? body.balance_infos?.first else {
            throw UsageError.server("DeepSeek 无余额信息")
        }
        let total = Double(info.total_balance) ?? 0
        return RawWindow(provider: "deepseek", name: "balance", label: nil,
                         utilization: 0, resets_at: nil,
                         balance: total, currency: info.currency)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var emails: [String: String] = [:]
    /// 数据对应的查询时间（服务端 queried_at）
    @Published private(set) var dataTime: Date?
    @Published private(set) var serverStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    /// 某家本次请求失败时，沿用它上次成功的数据；这里记录那份数据的时间
    @Published private(set) var providerStaleSince: [String: Date] = [:]
    @Published private(set) var providerErrors: [String: String] = [:]
    /// DeepSeek 余额请求的失败原因（未配置 Key 时为 nil）
    @Published private(set) var deepseekError: String?
    private var lastGoodAt: [String: Date] = [:]

    private(set) var lastAttempt: Date?
    private let settings: AppSettings
    private var pollTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        restoreCache()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var sections: [ProviderSection] {
        Sections.build(windows: windows, emails: emails, staleSince: providerStaleSince)
    }
    var hasData: Bool { !windows.isEmpty }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.settings.interval ?? AppSettings.defaultInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// 打开面板时调用：距上次请求超过 20 秒才刷新
    func refreshIfStale() {
        if let t = lastAttempt, Date().timeIntervalSince(t) < 20 { return }
        Task { await refresh() }
    }

    private var retryTask: Task<Void, Never>?

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.refresh()
        }
    }

    // MARK: 本地缓存：上次成功的窗口落盘，冷启动碰上 429 也有数可显示

    private struct Cache: Codable {
        var windows: [RawWindow]
        var lastGoodAt: [String: Date]
        var emails: [String: String]
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TidyUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-usage.json")
    }

    private func saveCache() {
        let cache = Cache(windows: windows.map(\.raw), lastGoodAt: lastGoodAt, emails: emails)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    private func restoreCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        // 超过 7 天的旧数据没意义
        let fresh = cache.lastGoodAt.filter { Date().timeIntervalSince($0.value) < 7 * 86400 }
        windows = cache.windows.map(UsageWindow.init(raw:)).filter { fresh[$0.provider] != nil }
        lastGoodAt = fresh
        emails = cache.emails
        dataTime = fresh.values.max()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastAttempt = Date()
        defer { isLoading = false }

        // 先在 MainActor 上捕获值
        let ep = settings.endpoint
        let tk = settings.token
        let dsKey = settings.deepseekKey

        // 并行：主端点 + DeepSeek
        async let mainResult: Result<UsageResponse, Error> = {
            guard !ep.isEmpty else { return .failure(UsageError.badURL) }
            do { return .success(try await UsageClient.fetch(endpoint: ep, token: tk)) }
            catch { return .failure(error) }
        }()
        async let dsResult: Result<RawWindow, Error> = {
            guard !dsKey.isEmpty else { return .failure(UsageError.noToken) }
            do { return .success(try await UsageClient.fetchDeepSeekBalance(apiKey: dsKey)) }
            catch { return .failure(error) }
        }()

        let main = await mainResult
        let ds = await dsResult

        let queried = Date()
        var freshWindows: [UsageWindow] = []
        var freshProviders = Set<String>()
        var mainOK = false

        // 主端点
        if case .success(let body) = main {
            let ws = (body.windows ?? []).map(UsageWindow.init(raw:))
            freshWindows.append(contentsOf: ws)
            let bodyQueried = body.queried_at.map { Date(timeIntervalSince1970: $0) } ?? queried
            for p in Set(ws.map(\.provider)) {
                freshProviders.insert(p)
                lastGoodAt[p] = bodyQueried
            }
            providerErrors = body.errors ?? [:]
            var mails = emails
            for (k, v) in body.emails ?? [:] { if let v { mails[k] = v } }
            if mails["claude"] == nil, let e = body.email { mails["claude"] = e }
            emails = mails
            serverStale = body.stale ?? false
            dataTime = bodyQueried
            mainOK = true
        }

        // DeepSeek
        switch ds {
        case .success(let raw):
            freshWindows.append(UsageWindow(raw: raw))
            freshProviders.insert("deepseek")
            lastGoodAt["deepseek"] = queried
            deepseekError = nil
        case .failure(let err):
            if case UsageError.noToken = err {
                deepseekError = nil   // 没填 Key 不算错误
            } else {
                deepseekError = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            }
        }

        // 合并旧数据
        var merged = freshWindows
        var staleSince: [String: Date] = [:]
        for p in Set(windows.map(\.provider)).subtracting(freshProviders) {
            merged += windows.filter { $0.provider == p }
            staleSince[p] = lastGoodAt[p]
        }
        windows = merged
        providerStaleSince = staleSince
        saveCache()

        if mainOK || !freshWindows.isEmpty {
            errorMessage = nil
        } else if case .failure(let err) = main {
            errorMessage = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
        }

        if !staleSince.isEmpty { scheduleRetry() }
    }
}
