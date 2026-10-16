#!/bin/bash
# Builds a universal (Intel + Apple Silicon) Andromax.app and a DMG with the installer into build/.
# Usage: VERSION=1.2.0 scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/Andromax.app"
DMG="build/Andromax-$VERSION.dmg"

xcodebuild -project Andromax/Andromax.xcodeproj -scheme Andromax -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  MARKETING_VERSION="$VERSION" build

# Fail loudly if any binary would not run on one of the two Mac architectures.
for binary in "$APP/Contents/MacOS/Andromax" "$APP"/Contents/Frameworks/*.dylib; do
  lipo "$binary" -verify_arch x86_64 arm64
done
codesign --verify --deep --strict "$APP"

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "installer/Install Andromax.command" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Andromax -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"
