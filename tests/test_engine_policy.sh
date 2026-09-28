#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export NAGARA_TEST_DIR="$TEST_DIR"
# 製品の Controller を使い、アプリの起動入口と個人設定の保存先だけを差し替える。
python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["NAGARA_TEST_DIR"])
app = Path("Sources/App.swift").read_text()
(root / "Controller.swift").write_text(app.split("@main\nenum Nagara")[0])
settings = Path("Sources/Settings.swift").read_text()
(root / "Settings.swift").write_text(settings.replace(
    "FileManager.default.homeDirectoryForCurrentUser",
    'URL(fileURLWithPath: ProcessInfo.processInfo.environment["NAGARA_TEST_DIR"]!)'))
PY
sources=()
for source in Sources/*.swift; do
  case "$source" in Sources/App.swift|Sources/Settings.swift) continue ;; esac
  sources+=("$source")
done
SDK="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" \
  "${sources[@]}" "$TEST_DIR/Controller.swift" "$TEST_DIR/Settings.swift" \
  tests/test_engine_policy.swift -o "$TEST_DIR/engine-policy-tests"
"$TEST_DIR/engine-policy-tests"
