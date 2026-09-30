# CPA 官方额度旁路接口（给 cc-switch 用）

背景：`http://YOUR_SERVER:8317` 跑的是 CLIProxyAPI（响应头 `X-Cpa-Version: main-1effc9b-patch2`），
同事通过 cc-switch 以 `http://YOUR_SERVER:8317/default/cs_xxxx` 接入。想在 cc-switch 里看到
Anthropic 官方的 5 小时 / 周额度。

## 结论

1. **不需要 SSL 证书**。cc-switch 只在「非自定义模板」下强制 HTTPS：
   `src-tauri/src/usage_script.rs:520` → `if !is_custom_template && scheme != "https" && !loopback { 报错 }`，
   `validate_base_url` 同理（`should_validate_base_url` 在自定义模板下直接返回 false）。
   预设模板选 **自定义**，就能用 `http://ip:port/...`，同源校验也一并跳过。
2. **需要服务端加接口**。CLIProxyAPI 自己没有暴露官方 5h/周额度：
   - `/v0/management/*` 是管理面（要管理密码），里面只有请求数/token 数统计；
   - 它对上游只记了 `anthropic-ratelimit-unified-*` 响应头（`sdk/cliproxy/auth/quota_signals.go`），
     那是 allowed/rejected + reset，没有百分比。
   - 官方百分比只有 `GET https://api.anthropic.com/api/oauth/usage`（要 OAuth access_token，
     只有服务器上有）。cc-switch 的「官方」模板正是打这个地址，但它读的是**本机** CLI 凭据，
     客户端没有 token，所以那个模板对中转用户没用。

所以做法：服务器上加一个只读小服务，把 OAuth 额度转成 JSON 给大家查。

## 已部署（YOUR_SERVER，2026-09-11）

| 项 | 值 |
|---|---|
| 代码 | `/opt/cpa-usage/usage_api.py` |
| 服务 | `systemctl status cpa-usage`（enabled + Restart=always） |
| 凭据目录 | `/root/CliRelay/auths`（Docker 容器 `cli-proxy-api` 的 bind mount） |
| 端口 | `8318`，已 `ufw allow 8318/tcp` |
| 口令 | `YOUR_TOKEN`，也存在 `/opt/cpa-usage/token.env` |
| 接口 | `http://YOUR_SERVER:8318/usage?token=...` |

换 token：改 `/etc/systemd/system/cpa-usage.service` 里的 `USAGE_TOKEN`，
`systemctl daemon-reload && systemctl restart cpa-usage`，再同步给同事改脚本 URL。

重新部署到别的机器：

```bash
mkdir -p /opt/cpa-usage
scp usage_api.py root@HOST:/opt/cpa-usage/
scp cpa-usage.service root@HOST:/etc/systemd/system/   # 改 USAGE_TOKEN / CPA_AUTH_DIR
systemctl daemon-reload && systemctl enable --now cpa-usage
curl "http://127.0.0.1:8318/usage?token=你的TOKEN"
```

期望输出：

```json
{"ok":true,"email":"xx@xx.com","windows":[
  {"name":"five_hour","utilization":12.3,"resets_at":"2026-09-11T05:00:00Z"},
  {"name":"seven_day","utilization":41.0,"resets_at":"..."}],
 "queried_at":1757554800}
```

防火墙放行 8318（或只放公司出口 IP）。

## cc-switch 配置

每个同事：供应商 → 配置用量查询 → 启用 → 预设模板选 **自定义** →
把 `../legacy/cc-switch-custom-script.js` 整段贴进「提取器代码」，把 URL 里的 token 换成实际值。
API Key / 请求地址两个框留空。自动查询间隔 5 分钟即可。

## 说明

- 只有一个官方账号，所有人看到的是同一份额度——正是需求。
- 服务端缓存 60s（`USAGE_TTL`），10 个人各 5 分钟轮询，打到 Anthropic 也最多 1 次/分钟。
- access_token 由 CLIProxyAPI 自己刷新，本服务只读文件，不写回、不参与刷新。
  如果返回 `token rejected (HTTP 401)`，说明 CPA 那边凭据过期，去管理面重新登录。
- token 走 HTTP 明文。介意的话：绑个域名用 Caddy 反代自动签证书，
  URL 换成 `https://域名/usage?token=...` 即可，脚本不用改。

## 备选方案（不推荐）

改 CLIProxyAPI 源码加一个 `/v0/quota` 路由，读 `internal/auth/claude` 的 token 再打官方接口。
效果一样，但要维护 fork、跟上游同步，不如旁路服务省事。
