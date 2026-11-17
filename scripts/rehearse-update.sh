#!/bin/bash
# Update rehearsal — runs this build's launch path against a synthetic v1 data folder
# and proves the v1 files come through untouched. No window, no network, no real data.
#
#   1. a temp root gets a copy of the frozen v1 fixture (Tests/…/Fixtures/v1)
#   2. sha256 of every v1 file is recorded
#   3. the app runs headless: `Bookkeeper --rehearse-launch <dir>` (prepareForLaunch,
#      opens PortfolioStore + SpendingStore, exits)
#   4. checks: every v1 file byte-identical · backups/pre-2.0.0/ holds identical copies ·
#      spending/schema.json exists · nothing else in the folder changed (bar the empty
#      pricehistory/ cache folder 1.x makes too)
#   5. a second launch changes nothing at all
#
# Usage:  bash scripts/rehearse-update.sh [path/to/Bookkeeper.app]
#   No path → builds Release into dist/DerivedData (the same build release.sh makes).
# Exit 0 = ✅ all checks passed, 1 = ❌. scripts/release.sh aborts on ❌.
set -uo pipefail
cd "$(dirname "$0")/.."

FIXTURE="BookkeeperCore/Tests/BookkeeperCoreTests/Fixtures/v1"
V1_FILES=(wallets.txt history.csv quotes.json)
EXPECTED_NEW=(backups backups/pre-2.0.0 spending spending/schema.json)
# The one empty folder 1.x already makes on every launch (PriceHistoryCache) — allowed as
# an empty folder only: anything written inside it still shows as a change.
EXPECTED_NEW+=(pricehistory)
for f in "${V1_FILES[@]}"; do EXPECTED_NEW+=("backups/pre-2.0.0/$f"); done

APP="${1:-}"
if [ -z "$APP" ]; then
  DERIVED="dist/DerivedData"
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null 2>&1 || true
  echo "🔨 build Release for the rehearsal"
  xcodebuild -project Bookkeeper.xcodeproj -scheme Bookkeeper -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build >/dev/null \
    || { echo "❌ build failed"; exit 1; }
  APP="$DERIVED/Build/Products/Release/Bookkeeper.app"
fi
BIN="$APP/Contents/MacOS/Bookkeeper"
[ -x "$BIN" ] || { echo "❌ no app binary at $BIN"; exit 1; }
VERSION="?"
[ -f "$APP/Contents/Info.plist" ] && VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bk-rehearse.XXXXXX") || { echo "❌ no temp root"; exit 1; }
trap 'rm -rf "$ROOT"' EXIT
DATA="$ROOT/data"
cp -R "$FIXTURE" "$DATA"
chmod 700 "$DATA"; chmod 600 "$DATA"/*

FAILS=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILS=$((FAILS + 1)); }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
# Every entry with its content hash (folders as "dir") — a full picture of the folder.
listing() { (cd "$1" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | while read -r p; do
  if [ -d "$p" ]; then echo "$p dir"; else echo "$p $(sha "$p")"; fi; done); }

declare -a BEFORE_SHA
for i in "${!V1_FILES[@]}"; do BEFORE_SHA[$i]=$(sha "$DATA/${V1_FILES[$i]}"); done
listing "$DATA" > "$ROOT/before.txt"

# Headless launch, with a ceiling: a hang is a failure, not a stuck release.
launch() {
  env -u BOOKKEEPER_DATA_DIR "$BIN" --rehearse-launch "$DATA" > "$ROOT/launch.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.25; waited=$((waited + 1))
    [ "$waited" -ge 120 ] && { kill -9 "$pid" 2>/dev/null; echo "timed out after 30s" >> "$ROOT/launch.log"; return 124; }
  done
  wait "$pid"
}

echo "🧪 rehearse update → v$VERSION against a synthetic v1 folder"
if launch; then pass "launch path ran and exited cleanly"
else fail "launch path exited $? — $(tail -1 "$ROOT/launch.log")"; fi
sed 's/^/     /' "$ROOT/launch.log" | grep -v '^ *$' | grep -v "$DATA" || true

for i in "${!V1_FILES[@]}"; do
  f="${V1_FILES[$i]}"
  [ "$(sha "$DATA/$f" 2>/dev/null)" = "${BEFORE_SHA[$i]}" ] \
    && pass "$f byte-identical" || fail "$f changed"
  [ "$(sha "$DATA/backups/pre-2.0.0/$f" 2>/dev/null)" = "${BEFORE_SHA[$i]}" ] \
    && pass "backups/pre-2.0.0/$f matches" || fail "backups/pre-2.0.0/$f missing or different"
done
[ -f "$DATA/spending/schema.json" ] && pass "spending/schema.json exists" || fail "spending/schema.json missing"

# Nothing else: the after-listing must be the before-listing plus exactly the expected entries.
listing "$DATA" > "$ROOT/after.txt"
cut -d' ' -f1 "$ROOT/before.txt" > "$ROOT/allowed.txt"
printf '%s\n' "${EXPECTED_NEW[@]}" >> "$ROOT/allowed.txt"
EXTRA=$(cut -d' ' -f1 "$ROOT/after.txt" | LC_ALL=C sort | comm -23 - <(LC_ALL=C sort -u "$ROOT/allowed.txt"))
CHANGED=$(LC_ALL=C comm -23 "$ROOT/before.txt" "$ROOT/after.txt")
if [ -z "$EXTRA" ] && [ -z "$CHANGED" ]; then pass "nothing else in the folder changed"
else
  fail "unexpected changes in the data folder"
  [ -n "$EXTRA" ] && echo "$EXTRA" | sed 's/^/       + /'
  [ -n "$CHANGED" ] && echo "$CHANGED" | sed 's/^/       ~ /'
fi

# A second launch (the 2.0 → 2.0 relaunch) must leave everything exactly as it is.
if launch && diff -q "$ROOT/after.txt" <(listing "$DATA") >/dev/null; then
  pass "second launch changed nothing"
else fail "second launch changed the folder"; fi

if [ "$FAILS" -eq 0 ]; then
  echo "✅ rehearsal passed — v1 data survives the update to v$VERSION"
  exit 0
fi
echo "❌ rehearsal FAILED ($FAILS check(s)) — do not release v$VERSION"
exit 1
