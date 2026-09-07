#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# private な状態への故障注入は一時ファイル内だけで行う。
cat Sources/Player.swift tests/test_audio.swift > "$TEST_DIR/AudioTests.swift"
swiftc -parse-as-library -swift-version 5 \
  Sources/Settings.swift Sources/Sanitizer.swift Sources/PlaybackDeadline.swift \
  Sources/ClipboardReader.swift "$TEST_DIR/AudioTests.swift" \
  -o "$TEST_DIR/audio-tests"
"$TEST_DIR/audio-tests"
