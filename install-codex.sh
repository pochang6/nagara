#!/bin/bash
# Codex 側の設置。
#
#   1. notify 用のスクリプトを ~/.codex/ に置く
#   2. ~/.codex/config.toml の notify 行を作って見せる（--apply で書き換える）
#
# notify は1つしか置けないので、すでに別のものが入っている場合は
# **その手前に nagara を挟んで、元のものへ渡す**形の行を作る。壊さないための作法。
#
# 既定では書き換えません。行を見て、納得してから --apply してください。
set -euo pipefail

cd "$(dirname "$0")"

CODEX_DIR="$HOME/.codex"
CONFIG="$CODEX_DIR/config.toml"
NOTIFY_PATH="$CODEX_DIR/nagara-codex-notify.sh"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$NOTIFY_PATH"
  echo "スクリプトを消しました。config.toml の notify 行は手で戻してください"
  exit 0
fi

mkdir -p "$CODEX_DIR"
install -m 0755 hooks/nagara-codex-notify.sh "$NOTIFY_PATH"
echo "==> 通知スクリプト: $NOTIFY_PATH"

LINE="$(python3 - "$CONFIG" "$NOTIFY_PATH" <<'PY'
import json, os, re, sys

config, notify = sys.argv[1], sys.argv[2]
existing = []
if os.path.exists(config):
    with open(config, encoding="utf-8") as handle:
        for raw in handle:
            if raw.strip().startswith("notify"):
                body = raw.split("=", 1)[1].strip() if "=" in raw else "[]"
                try:
                    existing = json.loads(body)
                except Exception:
                    existing = []
                break

# すでに nagara が入っているなら、そのまま
if any("nagara-codex-notify" in str(item) for item in existing):
    print("")
    sys.exit(0)

chain = [item for item in existing]
print("notify = " + json.dumps([notify] + chain))
PY
)"

if [ -z "$LINE" ]; then
  echo "==> config.toml: すでに nagara が入っています"
  exit 0
fi

echo
echo "config.toml にこの行を置いてください:"
echo
echo "  $LINE"
echo

if [ "${1:-}" != "--apply" ]; then
  echo "書き換えるなら: ./install-codex.sh --apply"
  exit 0
fi

cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
python3 - "$CONFIG" "$LINE" <<'PY'
import os, sys

config, line = sys.argv[1], sys.argv[2]
lines = []
if os.path.exists(config):
    with open(config, encoding="utf-8") as handle:
        lines = handle.readlines()

replaced = False
for index, raw in enumerate(lines):
    if raw.strip().startswith("notify"):
        lines[index] = line + "\n"
        replaced = True
        break
if not replaced:
    lines.insert(0, line + "\n")

with open(config, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
print("==> config.toml を書き換えました（元は .bak に残しています）")
PY
