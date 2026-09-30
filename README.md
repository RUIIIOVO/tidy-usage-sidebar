# Tidy Usage Sidebar

一个很轻的 macOS 菜单栏小工具，用来看 AI 订阅额度（Claude、Antigravity / Gemini）的 5 小时和每周用量。

```
✳ ⑤ ⑦   ᗑ ⑤ ⑦        ← 菜单栏：每家一个 logo，后面跟 5 小时环和 7 天环
```

- **菜单栏**：logo + 圆环。环里的 `5` 表示 5 小时窗口，`7` 表示周窗口，分模型的周额度用模型首字母（如 Fable → `F`）。环的填充表示已用比例；达到 80% 变橙，90% 变红，其余时候跟随菜单栏深浅色。
- **面板**：按服务商分组，每行显示名称、重置倒计时、已用百分比和进度条。点击任意一行，就能切换它是否显示在菜单栏上。
- 原生 SwiftUI + AppKit，没有 Dock 图标；Token 存在钥匙串里。

## 数据来源

App 本身不读取任何本机凭据，只从你自建的额度接口拉取 JSON：

```
GET <endpoint>          Authorization: Bearer <token>
{
  "ok": true,
  "emails": {"claude": "...", "antigravity": "..."},
  "windows": [
    {"provider": "claude", "name": "five_hour", "utilization": 12.3, "resets_at": "2026-09-30T03:00:00Z"},
    {"provider": "claude", "name": "seven_day", "utilization": 41.0, "resets_at": "..."},
    {"provider": "claude", "name": "weekly_scoped", "label": "Fable", "utilization": 11.0, "resets_at": "..."},
    {"provider": "antigravity", "name": "5h", "label": "Gemini Models", "utilization": 0.0, "resets_at": "..."}
  ],
  "stale": false,
  "queried_at": 1790734952
}
```

`utilization` 是已用百分比（0–100）。`server/` 目录里提供了一个参考实现：它读取 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 的 OAuth 凭据，调用各家官方额度接口后，按上面的格式返回。部署方法见 [server/README.md](server/README.md)。

## 构建

需要 macOS 14+ 和 Swift 5.9+（装 Xcode 或 Command Line Tools 都行）。

```bash
cp local.env.example local.env   # 可选：填服务地址 / token / HTTP 例外
scripts/build.sh                 # 编译 → 打包 .app → 签名 → 装到 ~/Applications 并启动
scripts/build.sh --no-install    # 只产出 build/Tidy Usage.app
```

- 如果额度服务走的是纯 HTTP，要在 `local.env` 里设置 `HTTP_HOST=<IP 或域名>`，构建时会只为这个主机开 ATS 例外。
- `USAGE_ENDPOINT` / `USAGE_TOKEN` 会在安装后自动写入 App（token 存进钥匙串）。你也可以不填，首次启动时在设置窗口里手动填。
- 签名：本机有 Apple Development 证书就用它签，否则用 ad-hoc 签名。

## 目录

```
App/        SwiftPM 工程（菜单栏图标、面板、设置）
server/     额度接口参考实现（Python，systemd 部署）
scripts/    构建脚本
design/     设计稿（HTML 静态 mock）
legacy/     旧的 cc-switch 用量脚本
```

## 许可

MIT。Claude logo 来自 [simple-icons](https://simpleicons.org)（CC0），Antigravity logo 来自 [lobe-icons](https://github.com/lobehub/lobe-icons)（MIT）；商标归各自所有者。
