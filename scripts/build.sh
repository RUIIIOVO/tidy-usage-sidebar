#!/usr/bin/env bash
# 编译 → 打成 .app → 签名 → 装到 ~/Applications 并重启
#   scripts/build.sh              # 编译、安装、启动
#   scripts/build.sh --no-install # 只产出 build/Tidy Usage.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 本机私有配置（不入库）：HTTP_HOST / USAGE_ENDPOINT / USAGE_TOKEN，见 local.env.example
[[ -f "$ROOT/local.env" ]] && source "$ROOT/local.env"
APP_NAME="Tidy Usage"
BUNDLE_ID="${BUNDLE_ID:-io.github.tidy-usage-sidebar}"
VERSION="1.0.0"
OUT="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
# 若额度服务是纯 HTTP，设置 HTTP_HOST=你的服务器 IP 或域名，为它单独开 ATS 例外
HTTP_HOST="${HTTP_HOST:-}"

cd "$ROOT/App"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TidyUsage"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/TidyUsage"
cp "$ROOT/App/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>TidyUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
$( [[ -n "$HTTP_HOST" ]] && cat <<ATS
    <key>NSExceptionDomains</key>
    <dict>
      <key>$HTTP_HOST</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
ATS
)
  </dict>
</dict>
</plist>
PLIST

# 有开发者证书就用它签（钥匙串授权跨重编译稳定），否则 ad-hoc
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')"
codesign --force --options runtime --sign "${IDENTITY:--}" "$OUT"
echo "signed with: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "built: $OUT"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
pkill -x TidyUsage 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$OUT" "$INSTALL_DIR/"
ARGS=()
[[ -n "${USAGE_ENDPOINT:-}" ]] && ARGS+=(--set-endpoint "$USAGE_ENDPOINT")
[[ -n "${USAGE_TOKEN:-}" ]] && ARGS+=(--set-token "$USAGE_TOKEN")
if (( ${#ARGS[@]} )); then
  open "$INSTALL_DIR/$APP_NAME.app" --args "${ARGS[@]}"
else
  open "$INSTALL_DIR/$APP_NAME.app"
fi
echo "installed: $INSTALL_DIR/$APP_NAME.app"
