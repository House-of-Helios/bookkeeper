#!/bin/bash
# Build "Bookkeeper Dev.app" into ${DEV_APP_DIR:-dist/dev}: the double-clickable dev build
# Helios opens on this Mac, for Spending work against fake data.
#
#   bash scripts/make-dev-app.sh                       (→ dist/dev)
#   DEV_APP_DIR=/some/folder bash scripts/make-dev-app.sh
#
# What makes it a separate app from the real Bookkeeper:
#   - bundle id com.houseofhelios.bookkeeper.dev, name "Bookkeeper Dev";
#   - data root = <repo>/_DevData/ (Info.plist BookkeeperDataDir + LSEnvironment
#     BOOKKEEPER_DATA_DIR), never ~/Library/Application Support/Bookkeeper/;
#   - never checks for or is offered updates (the app skips them for any bundle id
#     ending ".dev");
#   - no real API keys go into it.
# Only works on this Mac (the data path is baked in).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p "${DEV_APP_DIR:-dist/dev}"
OUTDIR="$(cd "${DEV_APP_DIR:-dist/dev}" && pwd)"
APP_NAME="Bookkeeper Dev.app"
DATA="$ROOT/_DevData"
DERIVED="dist/DevDerivedData"   # own derived data: never thrashes the release build
BUNDLE_ID="com.houseofhelios.bookkeeper.dev"

# Same regeneration as release.sh: project.yml stays the one source of the version.
command -v xcodegen >/dev/null && xcodegen generate >/dev/null 2>&1 || true

echo "🌱 seed _DevData"
mkdir -p "$DATA/inbox"
if [ -z "$(ls -A "$DATA/inbox" 2>/dev/null)" ]; then
  python3 scripts/gen-fake-bank-csvs.py --dev
else
  echo "   inbox already has files — left as is"
fi
python3 scripts/gen-fake-crypto.py --dev

echo "🔨 build Release (dev flavour, ad-hoc signed)"
xcodebuild -project Bookkeeper.xcodeproj -scheme Bookkeeper -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build >/dev/null
BUILT="$DERIVED/Build/Products/Release/Bookkeeper.app"
[ -d "$BUILT" ] || { echo "❌ app not found"; exit 1; }

# Staged beside the output (same volume) so the final mv is a rename, never a half copy.
STAGE="$(mktemp -d "$OUTDIR/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME"
cp -R "$BUILT" "$APP"

echo "🧪 retag as Bookkeeper Dev"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
$PB -c "Set :CFBundleName Bookkeeper Dev" "$PLIST"
$PB -c "Set :CFBundleDisplayName Bookkeeper Dev" "$PLIST"
$PB -c "Delete :BookkeeperDataDir" "$PLIST" 2>/dev/null || true
$PB -c "Add :BookkeeperDataDir string $DATA" "$PLIST"
$PB -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
$PB -c "Add :LSEnvironment dict" "$PLIST"
$PB -c "Add :LSEnvironment:BOOKKEEPER_DATA_DIR string $DATA" "$PLIST"

# The plist edit broke the build's signature; re-sign ad hoc, as the release build is.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

rm -rf "$OUTDIR/$APP_NAME.old"
[ -d "$OUTDIR/$APP_NAME" ] && mv "$OUTDIR/$APP_NAME" "$OUTDIR/$APP_NAME.old"
mv "$APP" "$OUTDIR/$APP_NAME"
rm -rf "$OUTDIR/$APP_NAME.old"

# Rebuilt in place, so Finder/Dock keep the cached entry (and LSEnvironment): re-register.
touch "$OUTDIR/$APP_NAME" "$OUTDIR/$APP_NAME/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$OUTDIR/$APP_NAME"

echo "✅ $OUTDIR/$APP_NAME  (data → $DATA)"
