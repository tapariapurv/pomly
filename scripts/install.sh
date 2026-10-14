#!/bin/bash
# Installs the latest Pomly for Mac:
#   curl -fsSL https://raw.githubusercontent.com/tapariapurv/pomly/main/scripts/install.sh | bash
set -euo pipefail
URL="https://github.com/tapariapurv/pomly/releases/latest/download/Pomly-macOS.zip"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "Downloading Pomly…"
curl -fsSL "$URL" -o "$TMP/Pomly.zip"
ditto -x -k "$TMP/Pomly.zip" "$TMP"
pkill -x Pomly 2>/dev/null || true
rm -rf /Applications/Pomly.app
mv "$TMP/Pomly.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Pomly.app 2>/dev/null || true # not notarized yet
open /Applications/Pomly.app
echo "Pomly is installed. Look for the dial in your menu bar."
