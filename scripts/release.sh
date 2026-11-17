#!/bin/bash
# Publish a release to GitHub (House-of-Helios/bookkeeper): the public way updates travel.
# Every Mac reads `appcast.json` from the latest release and installs `Bookkeeper.zip`
# only if its SHA-256 matches and the signature verifies (ReleaseFeed.swift). This is the
# only way the app updates.
#
# Usage:  NOTES="what changed" bash scripts/release.sh
#
# - Built in its own derived-data folder, apart from the dev and rehearsal builds.
# - Signed with the Ed25519 key in this Mac's login Keychain ("Bookkeeper release signing").
#   Lose that key and installed apps can't take updates any more: back it up.
# - Publishes the code first (scripts/publish.sh: the `public` branch, private paths left
#   out) and tags that commit v<version>, so a release is always code that's on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="House-of-Helios/bookkeeper"
PROJECT="Bookkeeper.xcodeproj"; SCHEME="Bookkeeper"
DERIVED="dist/ReleaseDerivedData"
OUT="dist/release"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null 2>&1 || true
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Bookkeeper/Info.plist)
NOTES="${NOTES:?NOTES=\"what changed\" is required}"
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "❌ uncommitted changes — commit first"; exit 1; }
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && { echo "❌ $TAG is already released — bump the version in project.yml"; exit 1; }
PRIV=$(security find-generic-password -s "Bookkeeper release signing" -a bookkeeper -w) \
  || { echo "❌ no release signing key in the Keychain"; exit 1; }

echo "🔨 build Release $TAG (ad-hoc signed, no keys)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build >/dev/null
APP="$DERIVED/Build/Products/Release/Bookkeeper.app"
[ -d "$APP" ] || { echo "❌ app not found"; exit 1; }

bash scripts/rehearse-update.sh "$APP" || { echo "❌ update rehearsal failed — not released"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Bookkeeper.zip"
(cd "$OUT" && shasum -a 256 Bookkeeper.zip > Bookkeeper.zip.sha256)
SHA=$(cut -d' ' -f1 "$OUT/Bookkeeper.zip.sha256")
SIG=$(printf '%s\n' "$PRIV" | swift scripts/release-sign.swift sign "$VERSION" "$SHA")
# The key the installed apps trust is the one baked into ReleaseFeed.swift. If the Keychain
# key isn't its pair, every app would refuse this release: stop here instead.
PUB=$(sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' BookkeeperCore/Sources/BookkeeperCore/ReleaseFeed.swift)
swift scripts/release-sign.swift verify "$PUB" "$VERSION" "$SHA" "$SIG" >/dev/null \
  || { echo "❌ the Keychain key doesn't match the app's public key — not released"; exit 1; }

# The last release's feed seeds the change log, newest first.
gh release download -R "$REPO" --pattern appcast.json --output "$OUT/previous.json" 2>/dev/null || true
VERSION="$VERSION" NOTES="$NOTES" SHA="$SHA" SIG="$SIG" python3 - "$OUT/previous.json" > "$OUT/appcast.json" <<'PY'
import json, os, sys
try:
    old = json.load(open(sys.argv[1]))
except Exception:
    old = {}
v = os.environ["VERSION"]
history = [{"version": v, "notes": os.environ["NOTES"]}] + [h for h in old.get("history", []) if h.get("version") != v]
json.dump({"version": v, "notes": os.environ["NOTES"], "file": "Bookkeeper.zip",
           "sha256": os.environ["SHA"], "signature": os.environ["SIG"], "history": history[:30]},
          sys.stdout, indent=1, ensure_ascii=False)
PY
rm -f "$OUT/previous.json"

bash scripts/publish.sh "Bookkeeper $VERSION — $NOTES"
git tag -a "$TAG" -m "Bookkeeper $VERSION" public && git push -q origin "$TAG"

echo "📦 release $TAG"
gh release create "$TAG" -R "$REPO" --title "Bookkeeper $VERSION" --notes "$NOTES" \
  "$OUT/Bookkeeper.zip" "$OUT/Bookkeeper.zip.sha256" "$OUT/appcast.json"

# Verify by download, as a user's app would get it: hash, signature, code signature, version.
CHECK=$(mktemp -d); trap 'rm -rf "$CHECK"' EXIT
gh release download "$TAG" -R "$REPO" --dir "$CHECK"
(cd "$CHECK" && shasum -a 256 -c Bookkeeper.zip.sha256 >/dev/null) || { echo "❌ downloaded zip doesn't match its checksum"; exit 1; }
swift scripts/release-sign.swift verify "$PUB" "$VERSION" "$SHA" "$SIG" >/dev/null || { echo "❌ downloaded feed's signature doesn't verify"; exit 1; }
ditto -x -k "$CHECK/Bookkeeper.zip" "$CHECK/app"
codesign --verify --strict --deep -R '=identifier "com.houseofhelios.bookkeeper"' "$CHECK/app/Bookkeeper.app" || { echo "❌ downloaded app's code signature fails"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$CHECK/app/Bookkeeper.app/Contents/Info.plist")" = "$VERSION" ] \
  || { echo "❌ downloaded app is not $VERSION"; exit 1; }
echo "🔍 verified by download: checksum, signature, code signature, version"
echo "✅ released $TAG — https://github.com/$REPO/releases/tag/$TAG"
