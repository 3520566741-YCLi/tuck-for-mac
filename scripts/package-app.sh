#!/bin/zsh
# 打包 Tuck.app（release、arm64），用固定开发证书签名。
#   ./scripts/package-app.sh            → dist/Tuck.app
#   ./scripts/package-app.sh --install  → 另外装到 /Applications（旧版先移到废纸篓）
# 改名只需改 APP_NAME。
set -euo pipefail
cd "${0:A:h}/.."

VERSION="2.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${SIGN_IDENTITY:--}"   # 没设就 ad-hoc 签名；有开发者证书可 export SIGN_IDENTITY="Apple Development: …"
APP_NAME="Tuck"
APP="dist/${APP_NAME}.app"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/DesktopFramesMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
# 看门狗：Tuck 异常退出时恢复桌面原图标的小进程（随 Tuck 启停，不是登录项）
cp "$BIN_DIR/TuckWatchdog" "$APP/Contents/MacOS/TuckWatchdog"
# 去掉调试符号：否则二进制里会留下编译机器上的目录路径（含用户名），也更小
strip -S "$APP/Contents/MacOS/${APP_NAME}" "$APP/Contents/MacOS/TuckWatchdog"
# 图标：Icon Composer 分层图标（Liquid Glass，系统自动生成深浅色 / 着色变体）编进 Assets.car，
# 同时生成旧系统用的 .icns。
ICON_TMP="$(mktemp -d)"
xcrun actool "$PWD/Support/AppIcon/Tuck.icon" --compile "$ICON_TMP" --app-icon Tuck --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null
cp "$ICON_TMP/Assets.car" "$ICON_TMP/Tuck.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.tuckformac.tuck</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>Tuck</string>
  <key>CFBundleIconName</key><string>Tuck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# 先签内部的看门狗，再签整个 App
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/TuckWatchdog"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  # 先退出正在运行的旧版（不论叫什么名字，同一个 bundle id）
  osascript -e 'tell application id "io.github.tuckformac.tuck" to quit' >/dev/null 2>&1 || true
  sleep 1
  # 同一 bundle id 的旧安装一律移到废纸篓，只留一个
  for old in "$DEST"; do
    [[ -e "$old" ]] && trash "$old"
  done
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
fi
