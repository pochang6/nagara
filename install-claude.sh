#!/bin/bash
# Claude Code 側の設置。
#
#   1. Stop フック本体を ~/.claude/hooks/ に置く
#   2. ~/.claude/settings.json の hooks.Stop に登録する（既存の設定は壊さない）
#   3. /speak と /stop と /yomi を ~/.claude/commands/ に置く
#   4. 読みの候補を渡す UserPromptSubmit フックを登録する
#
# 登録先は ~/.claude/settings.json なので、ターミナル版でもデスクトップ版でも同じように効く。
# 外すときは ./install-claude.sh --uninstall
set -euo pipefail

cd "$(dirname "$0")"

CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
COMMAND_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_PATH="$HOOK_DIR/nagara-stop-hook.sh"
YOMI_HOOK_PATH="$HOOK_DIR/nagara-yomi-hook.sh"

if [ "${1:-}" = "--uninstall" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
with open(path, encoding="utf-8") as handle:
    settings = json.load(handle)
hooks = settings.get("hooks", {})
stop = hooks.get("Stop", [])
kept = []
for matcher in stop:
    inner = [h for h in matcher.get("hooks", [])
             if "nagara-stop-hook" not in str(h.get("command", ""))]
    if inner:
        matcher["hooks"] = inner
        kept.append(matcher)
if kept:
    hooks["Stop"] = kept
else:
    hooks.pop("Stop", None)

submit = hooks.get("UserPromptSubmit", [])
kept_submit = []
for matcher in submit:
    inner = [h for h in matcher.get("hooks", [])
             if "nagara-yomi-hook" not in str(h.get("command", ""))]
    if inner:
        matcher["hooks"] = inner
        kept_submit.append(matcher)
if kept_submit:
    hooks["UserPromptSubmit"] = kept_submit
else:
    hooks.pop("UserPromptSubmit", None)
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
print("Stop フックを外しました")
PY
  rm -f "$HOOK_PATH" "$YOMI_HOOK_PATH" \
        "$COMMAND_DIR/speak.md" "$COMMAND_DIR/stop.md" "$COMMAND_DIR/yomi.md"
  echo "設置を解除しました"
  exit 0
fi

mkdir -p "$HOOK_DIR" "$COMMAND_DIR"
install -m 0755 hooks/nagara-stop-hook.sh "$HOOK_PATH"
install -m 0755 hooks/nagara-yomi-hook.sh "$YOMI_HOOK_PATH"
install -m 0644 commands/speak.md "$COMMAND_DIR/speak.md"
install -m 0644 commands/stop.md "$COMMAND_DIR/stop.md"
install -m 0644 commands/yomi.md "$COMMAND_DIR/yomi.md"
echo "==> フック:      $HOOK_PATH"
echo "==>              $YOMI_HOOK_PATH"
echo "==> コマンド:    /speak /stop /yomi"

python3 - "$SETTINGS" "$HOOK_PATH" "$YOMI_HOOK_PATH" <<'PY'
import json, os, sys

path, hook, yomi_hook = sys.argv[1], sys.argv[2], sys.argv[3]
settings = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        try:
            settings = json.load(handle)
        except Exception:
            print("settings.json を読めませんでした。手で登録してください", file=sys.stderr)
            sys.exit(1)

hooks = settings.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])

already = any(
    "nagara-stop-hook" in str(entry.get("command", ""))
    for matcher in stop
    for entry in matcher.get("hooks", [])
)
changed = False
if already:
    print("==> settings.json: Stop フックは登録済みでした")
else:
    stop.append({"hooks": [{"type": "command", "command": hook}]})
    changed = True
    print("==> settings.json: Stop フックを登録しました")

# 読みの候補は、応答の終わりではなく次の入力のついでに渡す。
# 終わりを止めると、急ぎでもない用事で毎回引き留めることになる
submit = hooks.setdefault("UserPromptSubmit", [])
already_yomi = any(
    "nagara-yomi-hook" in str(entry.get("command", ""))
    for matcher in submit
    for entry in matcher.get("hooks", [])
)
if already_yomi:
    print("==> settings.json: 読みのフックは登録済みでした")
else:
    submit.append({"hooks": [{"type": "command", "command": yomi_hook}]})
    changed = True
    print("==> settings.json: 読みのフックを登録しました")

if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
PY

echo
echo "Claude Code を開き直すと効き始めます。"
echo "応答が終わるたびに nagara へ渡りますが、鳴りはしません（自動再生は既定 OFF）。"
echo "聴きたくなったら ⌃⌥P を押すか、/speak と打ってください。"
