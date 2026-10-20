#!/bin/bash
# Source install: builds the app into ~/Applications and registers the launchd agent.
#   CONFIG   config.json to use (default ./config.json, created from config.example.json)
#   APP_NAME / APP_DIR / BUNDLE_ID are passed through to macos/build.sh.
# Uninstall the agent: ./install.sh --uninstall
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export CONFIG="${CONFIG:-$DIR/config.json}"
APP="${APP_DIR:-$HOME/Applications}/${APP_NAME:-Conflict Watch}.app"

if [ "${1:-}" = "--uninstall" ]; then
  "$APP/Contents/MacOS/ConflictWatch" uninstall-agent
  exit 0
fi

[ -f "$CONFIG" ] || cp "$DIR/config.example.json" "$CONFIG"
chmod +x "$DIR/run.sh" "$DIR/python/conflict_watch.py" "$DIR/typescript/conflict-watch.ts"
"$DIR/macos/build.sh"
"$APP/Contents/MacOS/ConflictWatch" install-agent
