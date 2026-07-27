#!/bin/bash
# Builds a signed, notarized, stapled Gital.app and packages it as a zip
# ready to attach to a GitHub release (and reference from the Homebrew cask).
#
# Usage:
#   Scripts/release.sh                # full release build (requires notary credentials)
#   SKIP_NOTARIZE=1 Scripts/release.sh  # local test: build + sign only
#
# Notarization uses the notarytool keychain profile named by $NOTARY_PROFILE
# (default: gital-notary). Store it once with:
#   xcrun notarytool store-credentials gital-notary \
#     --apple-id <apple-id> --team-id 8HUWJ2ZRK2
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-gital-notary}"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/Gital.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Gital.app"

VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' Gital.xcodeproj/project.pbxproj | head -1)
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from project.pbxproj" >&2
  exit 1
fi
ZIP_PATH="$BUILD_DIR/Gital-$VERSION.zip"

echo "==> Building Gital $VERSION"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release)"
xcodebuild -project Gital.xcodeproj -scheme Gital -configuration Release \
  archive -archivePath "$ARCHIVE_PATH" -quiet

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist Scripts/ExportOptions.plist \
  -exportPath "$EXPORT_PATH" -quiet

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_INFO=$(codesign --display --verbose=4 "$APP_PATH" 2>&1)
if ! grep -q "Authority=Developer ID Application" <<<"$SIGNING_INFO"; then
  echo "error: app is not signed with a Developer ID Application certificate" >&2
  exit 1
fi

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> SKIP_NOTARIZE=1: skipping notarization and stapling"
else
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$ZIP_PATH"

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"

  echo "==> Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

echo "==> Packaging"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo
echo "Release artifact: $ZIP_PATH"
echo "Version:          $VERSION"
echo "SHA256:           $SHA256"
