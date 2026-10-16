#!/bin/bash
# Builds the release artifacts into dist/:
#   Pomly-macOS.zip          Mac app (ad-hoc signed; not notarized)
#   Pomly-iOS-unsigned.ipa   iPhone/iPad app with the Watch app, for AltStore or Sideloadly to sign
#   Pomly-Extension.zip      Chromium browser extension (load unpacked)
# and writes the zip's sha256 into the Homebrew cask. --publish also creates the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
OUT=build.noindex/release
rm -rf dist "$OUT" && mkdir -p dist
xcodegen generate -q
# Direct download: built-in updater on, no sandbox (the App Store build keeps both off).
xcodebuild -scheme Pomly -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$OUT" -quiet \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DIRECT' MAC_ENTITLEMENTS=Pomly/PomlyMacDirect.entitlements build
ditto -c -k --keepParent "$OUT/Build/Products/Release/Pomly.app" dist/Pomly-macOS.zip
xcodebuild -scheme Pomly -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$OUT" -quiet CODE_SIGNING_ALLOWED=NO build
mkdir -p "$OUT/Payload" && cp -R "$OUT/Build/Products/Release-iphoneos/Pomly.app" "$OUT/Payload/"
(cd "$OUT" && zip -qry ../../dist/Pomly-iOS-unsigned.ipa Payload)
sed -i '' "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" extension/manifest.json
(cd extension && zip -qr ../dist/Pomly-Extension.zip . -x test.mjs '*.DS_Store')
SHA=$(shasum -a 256 dist/Pomly-macOS.zip | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/pomly.rb
# AltStore source: sideloaded iPhones and iPads update from it automatically.
python3 - "$VERSION" "$(stat -f%z dist/Pomly-iOS-unsigned.ipa)" <<'PY'
import json, sys, datetime
p = "docs/altstore.json"; j = json.load(open(p)); v, size = sys.argv[1], int(sys.argv[2])
app = j["apps"][0]
app["versions"] = [x for x in app["versions"] if x["version"] != v]
app["versions"].insert(0, {"version": v, "date": datetime.date.today().isoformat(), "size": size, "minOSVersion": "26.0",
    "downloadURL": f"https://github.com/tapariapurv/pomly/releases/download/v{v}/Pomly-iOS-unsigned.ipa",
    "localizedDescription": f"Pomly {v}. See the release notes on GitHub."})
json.dump(j, open(p, "w"), indent=2)
PY
echo "Built Pomly $VERSION into dist/ (zip sha256 $SHA)"
if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" dist/* --title "Pomly $VERSION" --notes-file scripts/release-notes.md
fi
