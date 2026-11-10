#!/bin/bash
# Builds and runs QuizSnapper's self-test against a local mock API server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Sources/QuizSnapper"
OUT="${TMPDIR:-/tmp}/quizsnapper-selftest"
mkdir -p "$OUT"
PORT=${PORT:-8765}
swiftc -O -o "$OUT/selftest" \
  "$SRC"/Providers/*.swift "$SRC"/Core/Models.swift "$SRC"/Core/DisguiseModels.swift "$SRC"/Core/AnswerParser.swift \
  "$SRC"/Core/Support.swift "$SRC"/Hotkeys/KeyCombo.swift "$SRC"/Capture/ScreenCapturer.swift \
  "$ROOT/tools/selftest/main.swift"
python3 -I "$ROOT/tools/selftest/mock_server.py" "$PORT" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 0.8
"$OUT/selftest" "$PORT"
