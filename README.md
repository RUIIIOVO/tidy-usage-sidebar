<div align="center">

<img src="docs/images/logo.png" width="128" alt="Tidy Usage">

# Tidy Usage

**轻量、克制、原生的 macOS 菜单栏 AI 额度看板**

<p>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI%20%2B%20AppKit-6366f1?style=flat-square" alt="SwiftUI + AppKit">
  <img src="https://img.shields.io/badge/License-MIT-gray?style=flat-square" alt="MIT">
</p>

</div>

<br>

<div align="center">
  <img src="docs/images/panel.png" alt="Panel" width="320">
</div>

<br>

在 macOS 菜单栏常驻显示 Claude、Antigravity (Gemini)、DeepSeek 等 AI 平台的额度与余额。拒绝臃肿进程，只为抬头一瞥即知余量。

<div align="center">
  <img src="docs/images/menubar.png" alt="Menu Bar" height="30">
</div>

---

## 特性

- **菜单栏环形进度 & 余额** — 额度类服务显示 Logo 与 `5`/`7` 环形进度；DeepSeek 余额显示 Logo 与实时金额（如 `¥19`）。≥ 80% 橙色预警，≥ 90% 红色警示（余额 < ¥5 橙色，< ¥1 红色），常态下单色融入系统菜单栏。
- **点击即时钉选** — 面板中点击任意行即可将该指标钉上 / 撤下菜单栏，未钉选行半透明弱化。未钉选任何指标时显示 `gauge.with.needle` 空状态。
- **原生毛玻璃面板 & 独立窗口** — 无边框 `NSPanel` 锚定菜单栏；同时支持独立主窗口，可自由拖拽、置顶常驻桌面，并支持隐藏 Dock 图标回到纯菜单栏模式。进度条下方显示自适应重置倒计时（< 24h 显示倒计时，≥ 24h 显示日期时间）。
- **零凭据风险** — 客户端向自建聚合端拉取脱敏数据，或直连官方 API（如 DeepSeek），Token / Key 均存入 macOS Keychain，无需写回明文配置。
- **相对更新时间** — 面板底部显示人性化更新时间（刚刚更新 / X 分钟前更新 / 昨天 HH:mm 更新），悬停可查看精确到秒的刷新时间与服务端取数时间。
- **429 容灾 & 离线缓存** — 上游 429 时保持上次成功数据，服务商不会闪退消失。磁盘持久化缓存，冷启动即刻展示历史用量。缺失服务商 30 秒后自动补拉。
- **防抖交互** — 刷新按钮整圈旋转不卡半截，退出二次确认，所有操作全面防抖节流。

---

## 快速上手

```bash
git clone https://github.com/RUIIIOVO/tidy-usage-sidebar.git
cd tidy-usage-sidebar

# 可选：配置 HTTP 例外域名
cp local.env.example local.env

# 编译 + 签名 + 安装至 ~/Applications 并启动
scripts/build.sh
```

首次启动后点击菜单栏图标 → 底部 ⚙️ 设置 → 填入自建查询接口地址和 Token → 保存并测试。

> 构建脚本自动检测 `Apple Development` 证书，无证书时回退 ad-hoc 签名。`local.env` 中配置 `HTTP_HOST` 可为指定域名打入 ATS 例外。

---

## 接口规范

客户端向自建端点发送请求：

```
GET /usage
Authorization: Bearer <TOKEN>
```

期望返回：

```json
{
  "ok": true,
  "windows": [
    {
      "provider": "claude",
      "name": "five_hour",
      "label": null,
      "utilization": 28.5,
      "resets_at": "2026-09-30T09:30:00Z"
    },
    {
      "provider": "antigravity",
      "name": "weekly",
      "label": "Gemini Models",
      "utilization": 92.4,
      "resets_at": "2026-10-01T12:00:00Z"
    },
    {
      "provider": "deepseek",
      "name": "balance",
      "label": null,
      "utilization": 0,
      "resets_at": null,
      "balance": 18.58,
      "currency": "CNY"
    }
  ],
  "queried_at": 1790734952
}
```

| 字段 | 说明 |
|------|------|
| `provider` | `claude` / `antigravity` / `deepseek`，其他值降级为首字母文本图标 |
| `name` | 含 `5h` / `five_hour` → 5 小时窗口；`weekly` / `seven_day` → 周窗口；`balance` → 余额 |
| `label` | 子模型标签，如 `Fable`（菜单栏环上显示首字母 `F`） |
| `utilization` | 已用百分比 0.0–100.0（余额类型为 0） |
| `resets_at` | ISO 8601 格式额度刷新时间（余额类型为 null） |
| `balance` | 可选，数值型余额（仅 `balance` 类型） |
| `currency` | 可选，货币代码如 `CNY` |

配套服务端参考实现见 [`server/`](server/) 目录。

---

## 项目结构

```
App/Sources/TidyUsage/
├── App.swift             # 状态栏生命周期与事件分发
├── MenuBarIcon.swift     # 菜单栏渲染（环形进度、预警着色、空状态）
├── MainWindow.swift      # 独立主窗口控制器（置顶、位置记忆）
├── PanelWindow.swift     # 无边框原生毛玻璃 NSPanel
├── PanelView.swift       # 交互看板（进度条、倒计时、钉选）
├── SettingsView.swift    # 设置窗口（Keychain 读写）
├── UsageStore.swift      # 轮询调度、429 容灾、磁盘缓存
├── Models.swift          # 数据模型与时间格式化
├── Debounce.swift        # 节流防抖
├── LogoPaths.swift       # 矢量 Logo 数据
└── SVGPath.swift         # 轻量矢量路径渲染
server/                   # Python 额度中继服务
scripts/build.sh          # 编译签名安装脚本
```

---

## 许可

[MIT](LICENSE)

Logo 版权：Claude 与 DeepSeek 徽标取自 [Simple Icons](https://simpleicons.org) (CC0)，Antigravity 徽标取自 [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT)，商标归各自所有者。
