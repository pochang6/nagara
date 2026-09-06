#!/bin/bash
# Claude Code の UserPromptSubmit フック。
#
# nagara が拾った「読みが怪しい語」が溜まっていたら、その一覧を次の応答の材料として渡す。
# 渡すだけで、登録するかどうかはエージェントが判断する。
#
# Stop フックではなくこちらに置いてあるのは、応答の終わりを止めたくないから。
# 読みの手当ては急ぎの用事ではないので、次にあなたが何か打ったついでに片付けばよい。
#
# 設置は ./install-claude.sh が面倒を見る。
set -uo pipefail

PORT="${NAGARA_PORT:-17371}"

# 本体が起きていなければ何もしない。ここで起こしにいくと、
# 読み上げを使っていない日にまでエンジンが立ち上がることになる
curl -sS -m 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1 || exit 0

PENDING="$(curl -sS -m 3 -X POST "http://127.0.0.1:$PORT/yomi/pending" \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null)" || exit 0

printf '%s' "$PENDING" | python3 -c '
import json, sys

try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)

rows = data.get("pending") or []
if not rows:
    sys.exit(0)

print("nagara が読み間違いの候補を見つけています。"
      "今回の返答のついでに、次の語を片付けてください。")
print("engine が実際の読み、mac は別の推定器の意見で、正解はまだ決まっていません。")
print("engine が誤りなら nagara yomi add <表層> <カタカナ> <アクセント型>、"
      "engine が正しいなら nagara yomi skip <表層>。")
print("人名のように文脈で読みが変わる語は登録せず skip にしてください。"
      "報告は1行ずつで十分です。")
for row in rows[:20]:
    print("- " + row["surface"] + "  engine=" + row["engine"] + "  mac=" + row["guess"] + "  文脈: " + row["context"][:40])
'
