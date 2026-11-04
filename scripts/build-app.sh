#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
case "${1:-}" in
  "") ;;
  --debug) CONFIGURATION=debug ;;
  *) echo "Usage: $0 [--debug]" >&2; exit 2 ;;
esac

cd "$PROJECT_ROOT"
swift build --product Newline --configuration "$CONFIGURATION" --arch arm64
BINARY_DIRECTORY="$(swift build --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP_DIRECTORY="$PROJECT_ROOT/outputs/Newline.app"

mkdir -p "$APP_DIRECTORY/Contents/MacOS" "$APP_DIRECTORY/Contents/Resources"
install -m 755 "$BINARY_DIRECTORY/Newline" "$APP_DIRECTORY/Contents/MacOS/Newline"
install -m 644 "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIRECTORY/Contents/Info.plist"

if [[ ! -f "$PROJECT_ROOT/Resources/Newline.icns" ]]; then
  swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$PROJECT_ROOT/work/Newline.iconset"
  iconutil --convert icns "$PROJECT_ROOT/work/Newline.iconset" --output "$PROJECT_ROOT/Resources/Newline.icns"
fi
install -m 644 "$PROJECT_ROOT/Resources/Newline.icns" "$APP_DIRECTORY/Contents/Resources/Newline.icns"

# SwiftPM resource bundles, when present, remain next to the executable.
for RESOURCE_BUNDLE in "$BINARY_DIRECTORY"/*.bundle; do
  [[ -e "$RESOURCE_BUNDLE" ]] || continue
  ditto "$RESOURCE_BUNDLE" "$APP_DIRECTORY/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done

install -m 644 "$PROJECT_ROOT/LICENSE" "$APP_DIRECTORY/Contents/Resources/NewlineLicense.txt"
install -m 644 "$PROJECT_ROOT/.build/checkouts/swift-cmark/COPYING" "$APP_DIRECTORY/Contents/Resources/ThirdPartyLicenses.txt"
plutil -lint "$APP_DIRECTORY/Contents/Info.plist"
codesign --force --sign - "$APP_DIRECTORY"
codesign --verify --strict "$APP_DIRECTORY"
echo "Built: $APP_DIRECTORY"
