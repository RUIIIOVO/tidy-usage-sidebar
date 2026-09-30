#!/usr/bin/env python3
"""
CLIProxyAPI 官方额度旁路接口 (sidecar)

读取 CLIProxyAPI 的 OAuth 凭据文件 -> 调各家官方额度接口 -> 以简单 JSON
暴露给 cc-switch。

目前覆盖两家:
  claude       GET  https://api.anthropic.com/api/oauth/usage
  antigravity  POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary

只读凭据，不写回；不触碰 CLIProxyAPI 的进程和配置。

任一家失败不影响另一家: 每家单独产出窗口，失败的那家只是没有窗口，
并在 errors 里留下原因。

环境变量:
  CPA_AUTH_DIR   凭据目录，默认 ~/.cli-proxy-api
  USAGE_PORT     监听端口，默认 8318
  USAGE_BIND     监听地址，默认 0.0.0.0
  USAGE_TOKEN    访问口令（必填建议）。客户端用 ?token=xxx 或 Authorization: Bearer xxx
  USAGE_TTL      上游缓存秒数，默认 60（N 个同事轮询也只打 Anthropic 1 次/分钟）

接口:
  GET /usage    -> {"ok":true,"email":..,"windows":[
                      {"provider":"claude","name":"five_hour","utilization":12.3,"resets_at":"..."},
                      {"provider":"antigravity","name":"5h","label":"Gemini Models",...}
                    ]}
  GET /healthz  -> ok

每个窗口都带 provider 字段，cc-switch 脚本据此分组显示。
"""

import json
import os
import time
import glob
import threading
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

AUTH_DIR = os.path.expanduser(os.environ.get("CPA_AUTH_DIR", "~/.cli-proxy-api"))
PORT = int(os.environ.get("USAGE_PORT", "8318"))
BIND = os.environ.get("USAGE_BIND", "0.0.0.0")
TOKEN = os.environ.get("USAGE_TOKEN", "").strip()
TTL = int(os.environ.get("USAGE_TTL", "60"))

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KNOWN = ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet")

# Antigravity(Google Cloud Code)额度接口。三个 host 是同一后端的不同入口，
# 逐个退避: sandbox 有时对新账号先可用，正式域名偶发 429。
ANTIGRAVITY_HOSTS = (
    "https://daily-cloudcode-pa.sandbox.googleapis.com",
    "https://daily-cloudcode-pa.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
)
ANTIGRAVITY_QUOTA_PATH = "/v1internal:retrieveUserQuotaSummary"
# 上游按 User-Agent 放行: 任意自定义 UA 会被 403 “no valid license” 抓住，
# 必须声明成 Antigravity 客户端。与 CliRelay 的
# internal/auth/antigravity/constants.go 保持一致。
ANTIGRAVITY_CLIENT_VERSION = "4.3.0"
ANTIGRAVITY_USER_AGENT = "vscode/1.X.X (Antigravity/%s)" % ANTIGRAVITY_CLIENT_VERSION

_lock = threading.Lock()
_cache = {"at": 0.0, "payload": None}


def load_credential(kind):
    """在 auth-dir 里找 type=<kind> 的凭据，取最新更新的那个。

    CLIProxyAPI 会把凭据按租户放进子目录，所以这里必须递归查找。
    """
    best = None
    for path in glob.glob(os.path.join(AUTH_DIR, "**", "*.json"), recursive=True):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        if data.get("type") != kind or not data.get("access_token"):
            continue
        mtime = os.path.getmtime(path)
        if best is None or mtime > best[0]:
            best = (mtime, path, data)
    return best[2] if best else None


def load_claude_credential():
    return load_credential("claude")


def fetch_claude_usage():
    """返回 (windows, email, error)。error 非 None 时 windows 为空。"""
    cred = load_credential("claude")
    if not cred:
        return [], None, "no claude credential found in %s" % AUTH_DIR

    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer %s" % cred["access_token"],
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "cpa-usage-sidecar/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:200]
        if e.code in (401, 403):
            return [], cred.get("email"), "token rejected (HTTP %d), 等 CLIProxyAPI 刷新或重新登录" % e.code
        return [], cred.get("email"), "anthropic HTTP %d: %s" % (e.code, detail)
    except Exception as e:
        return [], cred.get("email"), "request failed: %s" % e

    windows = build_windows(body)
    for w in windows:
        w["provider"] = "claude"
    return windows, cred.get("email"), None


def fetch_antigravity_usage():
    """返回 (windows, email, error)。

    上游返回的是 remainingFraction(剩余比例)，这里统一换算成 utilization
    (已用百分比)，让两家的窗口在同一个口径上，cc-switch 脚本只需一套换算。

    不传 project: 该账号没有自己的 project id。CLIProxyAPI 在这种情况下会退回
    一个共享 project，而按别人的 project 查出来的是那个 project 的余量
    (已耗尽的账号会显示成 100%)。空 body 让上游按 token 自身归属回答，
    宁可拿不到也不要拿错的。
    """
    cred = load_credential("antigravity")
    if not cred:
        return [], None, "no antigravity credential found in %s" % AUTH_DIR

    last_err = None
    for host in ANTIGRAVITY_HOSTS:
        req = urllib.request.Request(
            host + ANTIGRAVITY_QUOTA_PATH,
            data=b"{}",
            method="POST",
            headers={
                "Authorization": "Bearer %s" % cred["access_token"],
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": ANTIGRAVITY_USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "ignore")[:200]
            last_err = "antigravity HTTP %d: %s" % (e.code, detail)
            # 4xx(429 除外)每个 host 的答案都一样，不必再试。
            if 400 <= e.code < 500 and e.code != 429:
                break
            continue
        except Exception as e:
            last_err = "request failed: %s" % e
            continue

        windows = build_antigravity_windows(body)
        if windows:
            return windows, cred.get("email"), None
        last_err = "no quota bucket in response"

    return [], cred.get("email"), last_err or "unknown error"


def build_antigravity_windows(body):
    """retrieveUserQuotaSummary -> 统一窗口结构。

    结构: groups[].buckets[]，group 带模型族显示名(Gemini Models /
    Claude and GPT models)，bucket 带 window(5h / weekly)与 remainingFraction。
    """
    out = []
    groups = body.get("groups")
    if not isinstance(groups, list):
        return out
    for group in groups:
        if not isinstance(group, dict):
            continue
        group_label = group.get("displayName") or ""
        buckets = group.get("buckets")
        if not isinstance(buckets, list):
            continue
        for bucket in buckets:
            if not isinstance(bucket, dict):
                continue
            remaining = bucket.get("remainingFraction")
            if remaining is None:
                continue
            try:
                remaining = float(remaining)
            except (TypeError, ValueError):
                continue
            out.append(
                {
                    "provider": "antigravity",
                    "name": bucket.get("window") or bucket.get("bucketId") or "unknown",
                    "label": group_label,
                    "utilization": round((1.0 - remaining) * 100, 2),
                    "resets_at": bucket.get("resetTime"),
                }
            )
    return out


def fetch_usage():
    """两家分别取，互不拖累: 一家挂了另一家照常显示。"""
    windows = []
    errors = {}

    claude_windows, claude_email, claude_err = fetch_claude_usage()
    windows.extend(claude_windows)
    if claude_err:
        errors["claude"] = claude_err

    ag_windows, ag_email, ag_err = fetch_antigravity_usage()
    windows.extend(ag_windows)
    if ag_err:
        errors["antigravity"] = ag_err

    payload = {
        # 只要有一家给出窗口就算成功，避免一家掉线把整块面板打成错误态。
        "ok": bool(windows),
        "email": claude_email,
        "emails": {"claude": claude_email, "antigravity": ag_email},
        "windows": windows,
        "queried_at": int(time.time()),
    }
    if errors:
        payload["errors"] = errors
    if not windows:
        payload["error"] = "; ".join("%s: %s" % kv for kv in errors.items()) or "no window"
    return payload


def build_windows(body):
    """优先用 body["limits"]：它带模型显示名和每个窗口的 resets_at，
    顶层的 five_hour / nimbus_quill 那套代号字段会缺 resets_at。"""
    limits = body.get("limits")
    windows = []
    if isinstance(limits, list) and limits:
        for item in limits:
            if not isinstance(item, dict) or item.get("percent") is None:
                continue
            kind = item.get("kind")
            label = None
            if kind == "session":
                name = "five_hour"
            elif kind == "weekly_all":
                name = "seven_day"
            elif kind == "weekly_scoped":
                scope = item.get("scope") or {}
                model = (scope.get("model") or {}) if isinstance(scope, dict) else {}
                label = model.get("display_name") or model.get("id")
                name = "weekly_scoped"
            else:
                name = kind or "unknown"
            windows.append(
                {
                    "name": name,
                    "label": label,
                    "utilization": round(float(item["percent"]), 2),
                    "resets_at": item.get("resets_at"),
                }
            )
        return windows

    # 兜底：老结构的顶层窗口
    for name in KNOWN:
        w = body.get(name)
        if isinstance(w, dict) and w.get("utilization") is not None:
            windows.append(
                {
                    "name": name,
                    "label": None,
                    "utilization": round(float(w["utilization"]), 2),
                    "resets_at": w.get("resets_at"),
                }
            )
    return windows


def get_usage_cached():
    now = time.time()
    with _lock:
        if _cache["payload"] and now - _cache["at"] < TTL:
            return _cache["payload"]
        payload = fetch_usage()
        # 上游临时失败时继续返回上一次的成功结果，附带 stale 标记
        if not payload.get("ok") and _cache["payload"] and _cache["payload"].get("ok"):
            stale = dict(_cache["payload"])
            stale["stale"] = True
            stale["error"] = payload.get("error")
            return stale
        _cache["at"] = now
        _cache["payload"] = payload
        return payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self, query):
        if not TOKEN:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and header[7:].strip() == TOKEN:
            return True
        return query.get("token", [""])[0] == TOKEN

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/healthz":
            self._send(200, {"ok": True})
            return
        if parsed.path != "/usage":
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._authorized(query):
            self._send(401, {"ok": False, "error": "unauthorized"})
            return
        self._send(200, get_usage_cached())

    def log_message(self, fmt, *args):  # 静音访问日志
        pass


if __name__ == "__main__":
    if not TOKEN:
        print("WARNING: USAGE_TOKEN 未设置，接口对全网裸奔", flush=True)
    print("usage sidecar on %s:%d, auth-dir=%s, ttl=%ds" % (BIND, PORT, AUTH_DIR, TTL), flush=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
