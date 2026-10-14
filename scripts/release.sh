#!/bin/bash
# Builds the release artifacts into dist/:
#   Pomly-macOS.zip          Mac app (ad-hoc signed; not notarized)
#   Pomly-iOS-unsigned.ipa   iPhone/iPad app with the Watch app, for AltStore or Sideloadly to sign
# and writes the zip's sha256 into the Homebrew cask. --publish also creates the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
OUT=build/release
rm -rf dist "$OUT" && mkdir -p dist
xcodegen generate -q
xcodebuild -scheme Pomly -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$OUT" -quiet build
ditto -c -k --keepParent "$OUT/Build/Products/Release/Pomly.app" dist/Pomly-macOS.zip
xcodebuild -scheme Pomly -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$OUT" -quiet CODE_SIGNING_ALLOWED=NO build
mkdir -p "$OUT/Payload" && cp -R "$OUT/Build/Products/Release-iphoneos/Pomly.app" "$OUT/Payload/"
(cd "$OUT" && zip -qry ../../dist/Pomly-iOS-unsigned.ipa Payload)
SHA=$(shasum -a 256 dist/Pomly-macOS.zip | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/pomly.rb
echo "Built Pomly $VERSION into dist/ (zip sha256 $SHA)"
if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" dist/* --title "Pomly $VERSION" --notes-file scripts/release-notes.md
fi
