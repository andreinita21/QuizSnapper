#!/bin/bash
# QuizSnapper — build, sign, install and launch.
#
#   ./build.sh                     release build → ~/Applications/QuizSnapper.app → launch
#   ./build.sh --debug             debug build
#   ./build.sh --no-install        only build (bundle in ~/Library/Caches/QuizSnapper/build)
#   ./build.sh --reset-permissions forget the Screen Recording grant (fresh onboarding test)
#
# Why signing matters: macOS ties privacy permissions (Screen Recording) to the app's code
# signature. An ad-hoc signature changes on every build, so macOS "forgets" the permission
# each time. Signing with the same certificate every time keeps the grant across rebuilds.
# Override the certificate with SIGN_IDENTITY="<name or SHA-1>".
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
INSTALL=1
RESET=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-install) INSTALL=0 ;;
    --reset-permissions) RESET=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

BUNDLE_ID=com.andrei.quizsnapper
# Assemble outside the project: this folder lives on an iCloud-synced Desktop, and iCloud tags
# files with extended attributes that codesign rejects ("resource fork … detritus not allowed").
STAGE_DIR="${STAGE_DIR:-$HOME/Library/Caches/QuizSnapper/build}"
APP="$STAGE_DIR/QuizSnapper.app"
DEST_DIR="${INSTALL_DIR:-$HOME/Applications}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/QuizSnapper"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$STAGE_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuizSnapper"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Strip extended attributes (Finder info, quarantine…) — codesign rejects them.
xattr -cr "$APP"

# Pick a stable signing identity: Developer ID > Apple Development (first valid one).
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -E '"Developer ID Application' | head -1 | awk '{print $2}' || true)"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -E '"Apple Development' | head -1 | awk '{print $2}' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed -E 's/.*"(.*)"/\1/' | head -1)"
  codesign --force --options runtime --timestamp=none --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
else
  echo "⚠︎ No signing certificate found — signing ad-hoc."
  echo "  macOS will ask for Screen Recording again after every rebuild."
  echo "  Fix: open Xcode → Settings → Accounts and create an 'Apple Development' certificate."
  codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [ "$RESET" = 1 ]; then
  echo "▸ Resetting Screen Recording permission for $BUNDLE_ID"
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
fi

if [ "$INSTALL" = 1 ]; then
  echo "▸ Installing to $DEST_DIR"
  mkdir -p "$DEST_DIR"
  pkill -x QuizSnapper 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST_DIR/QuizSnapper.app"
  ditto --noextattr "$APP" "$DEST_DIR/QuizSnapper.app"
  codesign --verify --strict "$DEST_DIR/QuizSnapper.app"
  echo "▸ Launching"
  open "$DEST_DIR/QuizSnapper.app"
fi
echo "✓ Done"
