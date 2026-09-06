#!/bin/bash
# Codex の notify。
#
# 応答が終わるたびに、その本文を nagara へ黙って渡す。Claude Code の Stop フックと同じ扱い。
# Codex は turn が終わると notify に JSON を渡してくれて、その中に last-assistant-message が
# 丸ごと入っている。だから会話ログを解析する必要がない。
#
# notify は config.toml に1つしか置けない。すでに別のものを使っている場合のために、
# **最後の引数が Codex の JSON、それより手前は「そのまま渡す先」**という約束にしてある。
#
#   notify = ["…/nagara-codex-notify.sh", "…/元の通知プログラム", "元の引数"]
#
# こうしておけば、元の通知は今までどおり動いたまま nagara が横から受け取れる。
#
# 設置は ./install-codex.sh が面倒を見る。
set -uo pipefail

[ "$#" -ge 1 ] || exit 0
PAYLOAD="${!#}"

PORT="${NAGARA_PORT:-17371}"

send_to_nagara() {
  # Desktop の内部タスクも turn-complete を出す。本文の JSON らしさで弾くと、
  # 本人が頼んだ JSON の回答まで失うので、内部タスク固有の依頼文で見分ける。
  # 会話ログや Codex の内部 DB には依存させない（DESIGN.md 2.1節）。
  local body
  body="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, re, sys

try:
    payload = json.load(sys.stdin)
except (ValueError, TypeError):
    sys.exit(0)
if not isinstance(payload, dict) or payload.get("type") != "agent-turn-complete":
    sys.exit(0)

text = payload.get("last-assistant-message")
if not isinstance(text, str) or not text.strip():
    sys.exit(0)

inputs = payload.get("input-messages", [])
if not isinstance(inputs, list):
    sys.exit(0)
for message in inputs:
    if not isinstance(message, str):
        sys.exit(0)
    prompt = " ".join(message.split())
    if prompt.startswith((
        "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.",
        "You are an expert at upholding safety and compliance standards for Codex ambient suggestions.",
    )) or re.match(r"^(?:# Overview )?Generate \d+ to \d+ hyperpersonalized suggestions for what this user can do with Codex\b", prompt):
        sys.exit(0)
    if "nagara:internal" in message:
        sys.exit(0)

print(json.dumps({"text": text.strip(), "source": "Codex"}))
' 2>/dev/null)" || return 0
  [ -n "$body" ] || return 0

  # 本体が落ちていたら起こす。待つのは3秒まで。
  # 通知フックが理由で Codex が待たされるのは本末転倒
  if ! curl -sS -m 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
    [ -d /Applications/nagara.app ] && open -g -a /Applications/nagara.app 2>/dev/null || true
    up=0
    for _ in 1 2 3 4 5 6; do
      sleep 0.5
      if curl -sS -m 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then up=1; break; fi
    done
    [ "$up" = "1" ] || return 0
  fi

  printf '%s' "$body" | python3 -c '
import sys, urllib.request

body = sys.stdin.read().encode()
request = urllib.request.Request(
    "http://127.0.0.1:" + sys.argv[1] + "/speak",
    data=body, headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(request, timeout=5).read()
except Exception:
    pass
' "$PORT" >/dev/null 2>&1
}

send_to_nagara

# 元の通知プログラムがあれば、そちらへ渡して終わる
if [ "$#" -gt 1 ]; then
  exec "${@:1:$#-1}" "$PAYLOAD"
fi
