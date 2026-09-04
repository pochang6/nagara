#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="nagara"
BUNDLE_ID="dev.pochang6.nagara"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

# 署名について。
#
# nagara はホットキーに Carbon の RegisterEventHotKey を使うので、入力監視も
# アクセシビリティも要らない。つまり nobetsu のように「アドホック署名だとダイアログすら
# 出ずに拒否される」という事故は起きない。
#
# それでも署名はしておく。ログイン項目（SMAppService）と right-click のサービス登録は
# 署名の同一性で識別されるため、ビルドのたびに別アプリ扱いになると設定が積み上がる。
#
# 証明書名は NAGARA_IDENTITY で指定できる。指定が無ければ nagara → 手元にある唯一の
# 証明書、の順に探す。nobetsu 用に作った自己署名証明書がそのまま使える。
resolve_identity() {
  if [ -n "${NAGARA_IDENTITY:-}" ]; then
    echo "$NAGARA_IDENTITY"
    return
  fi
  if can_sign_with "nagara"; then
    echo "nagara"
    return
  fi
  local only
  only="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p' | sort -u)"
  if [ "$(echo "$only" | grep -c .)" = "1" ] && [ -n "$only" ]; then
    echo "$only"
    return
  fi
  echo ""
}

# 「一覧に出るか」ではなく「実際に署名できるか」で判断する。
# 信頼設定の差で、一覧に出ないのに署名できることがある
can_sign_with() {
  local identity="$1" dir probe
  [ -n "$identity" ] || return 1
  dir="$(mktemp -d)"
  probe="$dir/probe"
  cp /bin/echo "$probe"
  if codesign --force --sign "$identity" --timestamp=none "$probe" >/dev/null 2>&1; then
    rm -rf "$dir"; return 0
  fi
  rm -rf "$dir"; return 1
}

certificate_help() {
  cat <<'MSG'
  自己署名の証明書を1つ作れば済みます（1回だけの作業です）。

    1. 「キーチェーンアクセス」を開く
    2. メニューの「キーチェーンアクセス」>「証明書アシスタント」>「自分に証明書を作成」
    3. 名前            : nagara
       固有名のタイプ  : 自己署名ルート
       証明書のタイプ  : コード署名
    4. 作った証明書をダブルクリック >「信頼」>「コード署名」を「常に信頼」にする
    5. ./build.sh をやり直す

  すでに他の用途で作った証明書があるなら、それを使っても構いません:

    NAGARA_IDENTITY="証明書の名前" ./build.sh
MSG
}

IDENTITY="$(resolve_identity)"

if [ "${1:-}" = "--check" ]; then
  if [ -n "$IDENTITY" ]; then
    echo "✅ 証明書「${IDENTITY}」で署名できます"
    exit 0
  fi
  echo "❌ 署名に使える証明書が見つかりません"
  echo
  certificate_help
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# NSServices を宣言すると、選択したテキストを右クリック →「nagara で読む」で送れる。
# 画面を舐めるのではなく、選んだところだけを受け取るための入口
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>nagara</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>nagara で読む</string></dict>
      <key>NSMessage</key><string>speakSelection</string>
      <key>NSPortName</key><string>nagara</string>
      <key>NSSendTypes</key>
      <array><string>NSStringPboardType</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> compiling"
swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos26.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework Network \
  -framework ServiceManagement \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

if [ -n "$IDENTITY" ]; then
  echo "==> signing ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "⚠️  署名できる証明書が無いので、アドホック署名にします"
  echo "   （ログイン項目と右クリックのサービス登録が安定しません）"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

# 決まった場所に置く。パスが動くとログイン項目もサービス登録も迷子になる
INSTALLED="/Applications/$APP_NAME.app"
echo "==> installing to $INSTALLED"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

# CLI もあわせて置く。Codex でも cron でも自作スクリプトでも、これ1本で投げ込める。
# /usr/local/bin は sudo が要ることがあるので、書ける場所を PATH から探す
CLI_DIR=""
for candidate in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
  case ":$PATH:" in *":$candidate:"*) ;; *) continue ;; esac
  if [ -d "$candidate" ] && [ -w "$candidate" ]; then CLI_DIR="$candidate"; break; fi
done
if [ -n "$CLI_DIR" ]; then
  install -m 0755 bin/nagara "$CLI_DIR/nagara"
  echo "==> installed CLI: $CLI_DIR/nagara"
else
  echo "==> CLI は手で置いてください:"
  echo "    mkdir -p ~/.local/bin && install -m 0755 bin/nagara ~/.local/bin/nagara"
fi

echo "==> built:     $(pwd)/$APP"
echo "==> installed: $INSTALLED"
echo
echo "起動するには: open \"$INSTALLED\""
