#!/bin/bash
# Build a Release Bookkeeper.app and package it into a distributable DMG.
#
# No Apple Developer ID is required: the app is ad-hoc signed ("Sign to Run Locally").
# On the receiving Mac, the first launch needs a right-click → Open (Gatekeeper shows
# "unidentified developer" for un-notarized apps), or:  xattr -dr com.apple.quarantine /Applications/Bookkeeper.app
#
# For public/Gatekeeper-clean distribution you'd need a paid Apple Developer account:
# a "Developer ID Application" cert to sign, then notarize + staple. Hooks are noted below.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="Bookkeeper.xcodeproj"
SCHEME="Bookkeeper"
DIST="dist"
DERIVED="$DIST/DerivedData"

echo "🧹 clean dist"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "🔨 build Release (ad-hoc signed)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/Bookkeeper.app"
[ -d "$APP" ] || { echo "❌ app not found at $APP"; exit 1; }

# --- For a real Developer ID build, replace the line above's CODE_SIGN flags with your
#     identity, then after build:
#     codesign --deep --force --options runtime --sign "Developer ID Application: <NAME> (<TEAM>)" "$APP"
#     xcrun notarytool submit ... --wait ; xcrun stapler staple "$APP"

echo "📦 stage + build DMG"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Bookkeeper.dmg"
hdiutil create -volname "Bookkeeper" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# --- Update feed (appcast.json) ---------------------------------------------------------
# The app pings this file on launch. Set DIST_REPO to your PUBLIC releases repo (owner/name);
# the DMG is expected to be the v<version> release asset there. Source stays private.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Bookkeeper/Info.plist)
DIST_REPO="${DIST_REPO:-CHANGE-ME/bookkeeper-dist}"
NOTES="${NOTES:-}"
cat > "$DIST/appcast.json" <<JSON
{
  "version": "$VERSION",
  "url": "https://github.com/$DIST_REPO/releases/download/v$VERSION/Bookkeeper.dmg",
  "notes": "$NOTES"
}
JSON

echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
echo "✅ $DIST/appcast.json (version $VERSION → $DIST_REPO)"
echo
echo "Release: create a v$VERSION release on the PUBLIC $DIST_REPO with Bookkeeper.dmg attached,"
echo "         and commit appcast.json to its main branch. The app picks it up on next launch."
echo "   Manual install: open the DMG, drag Bookkeeper to Applications."
echo "   First launch on a new Mac: right-click Bookkeeper → Open (un-notarized)."
