#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Vocab"
BUNDLE_ID="com.swainyun.Vocab"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Vocab.xcodeproj"
INSTALL_BUNDLE="/Applications/$APP_NAME.app"
CONFIGURATION="Debug"
BUILD_DIR="$ROOT_DIR/build"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  --install|install|--install-verify|install-verify)
    CONFIGURATION="Release"
    BUILD_DIR="$ROOT_DIR/release-build"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install|--install-verify]" >&2
    exit 2
    ;;
esac

APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  build

# Quit the running app only once a replacement build exists, and wait until it
# has exited so two instances never share the store and launch checks cannot
# mistake the old process for the new one.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for attempt in $(seq 1 20); do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.5
done
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "$APP_NAME did not quit within 10 seconds; not launching the new build." >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

# Waits up to 10 s for the app process instead of a fixed one-second sleep.
wait_for_launch() {
  local attempt
  for attempt in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null && return 0
    sleep 0.5
  done
  echo "$APP_NAME did not launch within 10 seconds." >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_launch
    ;;
  --install|install)
    /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
    /usr/bin/open -n "$INSTALL_BUNDLE"
    ;;
  --install-verify|install-verify)
    /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
    /usr/bin/open -n "$INSTALL_BUNDLE"
    test -d "$INSTALL_BUNDLE"
    wait_for_launch
    ;;
esac
