#!/bin/bash
#
# Сборка ExternalIPMenuBar.app без полного Xcode — только Command Line Tools.
# Использование:  ./build.sh           — собрать в ./build/ExternalIPMenuBar.app
#                 ./build.sh --install  — собрать и установить в /Applications, затем запустить
#
set -euo pipefail

APP_NAME="ExternalIPMenuBar"
BUNDLE_ID="zvnic.ExternalIPMenuBar"
DEPLOY_TARGET="14.0"
SRC="${APP_NAME}/${APP_NAME}App.swift"
ICNS="${APP_NAME}/Assets.xcassets/external_ip_app.icns"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ARCH="$(uname -m)"   # arm64 на Apple Silicon, x86_64 на Intel
APP="build/${APP_NAME}.app"
MACOS_DIR="${APP}/Contents/MacOS"
RES_DIR="${APP}/Contents/Resources"

echo "==> Очистка"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Компиляция ($ARCH, macOS ${DEPLOY_TARGET}+)"
swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -framework SwiftUI -framework AppKit -framework Network -framework ServiceManagement \
    "$SRC" \
    -o "${MACOS_DIR}/${APP_NAME}"

if [ -f "$ICNS" ]; then
    cp "$ICNS" "${RES_DIR}/${APP_NAME}.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>${APP_NAME}</string>"
else
    ICON_KEY=""
fi

echo "==> Info.plist"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
    <key>LSUIElement</key><true/>
    ${ICON_KEY}
</dict>
</plist>
PLIST

echo "APPL????" > "${APP}/Contents/PkgInfo"

# Подпись: по умолчанию ad-hoc (-).
# Для переноса на другие Mac без предупреждений Gatekeeper укажите Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Имя (TEAMID)" ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> Ad-hoc подпись (для запуска на этой машине; автозапуск через SMAppService)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    echo "==> Подпись Developer ID + hardened runtime: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "    Для нотаризации: см. SIGNING.md"
fi

echo "==> Готово: $APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> Установка в /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "==> Запущено из /Applications"
fi
