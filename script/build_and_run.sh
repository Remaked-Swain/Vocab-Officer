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

if [[ "$MODE" == "--install" || "$MODE" == "install" || "$MODE" == "--install-verify" || "$MODE" == "install-verify" ]]; then
  CONFIGURATION="Release"
  BUILD_DIR="$ROOT_DIR/release-build"
fi

APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS' \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --install|install)
    /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
    /usr/bin/open -n "$INSTALL_BUNDLE"
    ;;
  --install-verify|install-verify)
    /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
    /usr/bin/open -n "$INSTALL_BUNDLE"
    sleep 1
    test -d "$INSTALL_BUNDLE"
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install|--install-verify]" >&2
    exit 2
    ;;
esac
