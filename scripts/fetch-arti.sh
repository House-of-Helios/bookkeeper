#!/bin/bash
# Put Arti (the Tor Project's Rust Tor client) where the build bundles it: vendor/arti.
# The universal binary XMRange builds reproducibly (XMRange/tools/build-arti.sh, pinned
# arti-v2.6.0, system libraries only) — one Arti for the House, not two builds of it.
# vendor/ is gitignored; the build copies vendor/arti into Bookkeeper.app/Contents/MacOS.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${ARTI_SRC:-$HOME/HouseOfHelios/XMRange/vendor/universal/arti}"
WANT="Arti 2.6.0"

[ -x "$SRC" ] || { echo "❌ no Arti at $SRC — build it with XMRange/tools/build-arti.sh"; exit 1; }
"$SRC" --version | head -1 | grep -qx "$WANT" || { echo "❌ $SRC is not $WANT"; exit 1; }
lipo -archs "$SRC" | grep -q x86_64 && lipo -archs "$SRC" | grep -q arm64 \
  || { echo "❌ $SRC is not universal (arm64 + x86_64)"; exit 1; }
# Library lines only (a universal binary also prints an "(architecture …)" header per slice).
if otool -L "$SRC" | grep -E "^\s+/" | grep -v -e "^\s*/usr/lib/" -e "^\s*/System/Library/"; then
  echo "❌ Arti links a non-system library"; exit 1
fi
mkdir -p vendor
cp "$SRC" vendor/arti.tmp && chmod 755 vendor/arti.tmp && mv -f vendor/arti.tmp vendor/arti
echo "🧅 vendor/arti ← $WANT ($(lipo -archs vendor/arti))"

# house-report: the House's one problem-report sender (XMRange/crates/house-report, built by
# XMRange/tools/build-house-report.sh). Report on stdin → NIP-59 gift wrap to the House key →
# Nostr relays, only through the loopback SOCKS port it is given. Pinned by checksum.
HR_SRC="${HOUSE_REPORT_SRC:-$HOME/HouseOfHelios/XMRange/vendor/universal/house-report}"
HR_SHA="b3c0b98597f1eb8fcbee026bd1e8fb47f8d39d84c88d959af2d895132404660a"   # house-report 0.1.0
[ -x "$HR_SRC" ] || { echo "❌ no house-report at $HR_SRC — build it with XMRange/tools/build-house-report.sh"; exit 1; }
[ "$(shasum -a 256 "$HR_SRC" | cut -d' ' -f1)" = "$HR_SHA" ] || { echo "❌ $HR_SRC is not house-report 0.1.0 (checksum)"; exit 1; }
if otool -L "$HR_SRC" | grep -E "^\s+/" | grep -v -e "^\s*/usr/lib/" -e "^\s*/System/Library/"; then
  echo "❌ house-report links a non-system library"; exit 1
fi
cp "$HR_SRC" vendor/house-report.tmp && chmod 755 vendor/house-report.tmp && mv -f vendor/house-report.tmp vendor/house-report
echo "📮 vendor/house-report ← 0.1.0 ($(lipo -archs vendor/house-report))"
