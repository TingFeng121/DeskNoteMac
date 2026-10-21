#!/bin/bash
# Build DeskNote.app from SwiftPM executable, ad-hoc signed, ready to `open`.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/桌面便签.app"

swift build -c "$CONFIG" --arch arm64
BIN_A=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/DeskNote
swift build -c "$CONFIG" --arch x86_64
BIN_X=$(swift build -c "$CONFIG" --arch x86_64 --show-bin-path)/DeskNote
BIN=$(mktemp)
lipo -create -output "$BIN" "$BIN_A" "$BIN_X"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskNote"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 固定身份签名：ad-hoc 每次构建 cdhash 都变，钥匙串会反复要求重新授权（见 Tools/make-signing-identity.sh）
SIGN_ID="${DESKNOTE_SIGN_ID:-DeskNote Local}"
BUNDLE_ID="local.desknote.app"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    # 光换身份还不够：codesign 给自签证书的默认 designated requirement 就是 cdhash 本身，
    # 于是每次重编都要重新授权。这里把 DR 钉成「同一张证书 + 同一个 bundle id」，
    # cdhash 再变也是同一个人，钥匙串的「始终允许」点一次就永久生效。
    CERT_SHA1=$(security find-identity -p codesigning 2>/dev/null \
        | awk -v n="\"$SIGN_ID\"" 'index($0, n) {print toupper($2); exit}')
    REQ="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
    SIGN=(--sign "$SIGN_ID" --identifier "$BUNDLE_ID" --requirements "=$REQ")
else
    echo "没有「$SIGN_ID」签名身份。ad-hoc 签名的 cdhash 每次都变，用它写进钥匙串的条目"
    echo "以后再也认不回来（就是反复弹密码框的根因）。先跑 Tools/make-signing-identity.sh"
    echo "重建身份；确实只想临时试一下再设 DESKNOTE_ALLOW_ADHOC=1。"
    [ "${DESKNOTE_ALLOW_ADHOC:-0}" = "1" ] || exit 1
    SIGN=(-s -)
fi
codesign --force "${SIGN[@]}" "$APP/Contents/MacOS/DeskNote" >/dev/null
codesign --force "${SIGN[@]}" "$APP" >/dev/null

echo "Built: $APP"
rm -f "$BIN"
