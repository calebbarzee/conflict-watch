#!/bin/bash
# Builds the standalone release zip: dist/Conflict-Watch-<VERSION>-macos.zip
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export VERSION="${VERSION:-1.0.0}" RELEASE=1 APP_DIR="$DIR/dist"
rm -rf "$DIR/dist"
"$DIR/macos/build.sh"
(cd "$DIR/dist" && ditto -c -k --keepParent "Conflict Watch.app" "Conflict-Watch-$VERSION-macos.zip")
echo "$DIR/dist/Conflict-Watch-$VERSION-macos.zip"
