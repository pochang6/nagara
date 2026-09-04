#!/bin/bash
# Claude Code の Stop フック。
#
# 応答が終わるたびに、その本文を nagara へ黙って渡す。**鳴らさない。**
# こうしておくと「これ聴きたい」と思った時点で、それはもう手元にある。
# あとは ⌃⌥P を押すか /speak と打つだけでよく、カーソルで擦る必要がない。
#
# ターミナルの表示ではなく会話ログから本文を取るので、
# プロンプト記号も進捗表示も混ざらない。
#
# 設置は ./install-claude.sh が面倒を見る。
set -uo pipefail

PORT="${NAGARA_PORT:-17371}"
export NAGARA_PORT="$PORT"
PAYLOAD="$(cat)"

# 本体が起きていなければ何もしない。フックが理由で Claude Code が止まるのは避ける
curl -sS -m 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1 || exit 0

printf '%s' "$PAYLOAD" | python3 -c '
import json, os, sys, urllib.request

try:
    payload = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)

path = payload.get("transcript_path")
if not path or not os.path.exists(path):
    sys.exit(0)

# 会話ログは1行1レコードの JSONL。末尾から遡って直近の assistant 発言を拾う
last_assistant = None
last_user = None
try:
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()
except Exception:
    sys.exit(0)

def text_of(record):
    message = record.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = [b.get("text", "") for b in content
             if isinstance(b, dict) and b.get("type") == "text"]
    return "\n".join(p for p in parts if p)

for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except Exception:
        continue
    kind = record.get("type")
    if kind == "assistant" and last_assistant is None:
        body = text_of(record)
        if body.strip():
            last_assistant = body
    elif kind == "user" and last_assistant is not None:
        last_user = text_of(record)
        break

if not last_assistant:
    sys.exit(0)

# 「/speak」と打った直後の「再生しました」まで積むと、次にそれを朗読する羽目になる。
# 操作のための往復はキューに入れない
if last_user:
    head = last_user.strip().lower()
    if head.startswith(("/speak", "/stop", "/nagara")) or head in ("喋って", "しゃべって", "読んで"):
        sys.exit(0)

body = json.dumps({
    "text": last_assistant,
    "source": "Claude Code",
}, ensure_ascii=False).encode("utf-8")

port = os.environ.get("NAGARA_PORT", "17371")
request = urllib.request.Request(
    "http://127.0.0.1:" + port + "/speak",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(request, timeout=5).read()
except Exception:
    pass
' 2>/dev/null

exit 0
