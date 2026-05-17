#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacCompanionCLI"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"

case "$MODE" in
  run)
    "$APP_BINARY"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    "$APP_BINARY"
    ;;
  --telemetry|telemetry)
    "$APP_BINARY"
    ;;
  --verify|verify)
    "$APP_BINARY" >/tmp/mac-companion.log 2>&1 &
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

