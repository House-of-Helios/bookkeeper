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
