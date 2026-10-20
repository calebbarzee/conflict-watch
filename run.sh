#!/bin/bash
# launchd entry point: runs the engine chosen in config.json ("python" or "typescript").
# Usage: run.sh [--config PATH] [--force]   (config defaults to $CONFLICT_WATCH_CONFIG, else ./config.json)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${CONFLICT_WATCH_CONFIG:-$DIR/config.json}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--config" ] && CONFIG="${args[$((i + 1))]}"
done
export CONFLICT_WATCH_CONFIG="$CONFIG"

engine=$(plutil -extract engine raw -o - "$CONFIG" 2>/dev/null || echo python)
case "$engine" in
  typescript) exec node "$DIR/typescript/conflict-watch.ts" "$@" ;;
  *)          exec python3 "$DIR/python/conflict_watch.py" "$@" ;;
esac
