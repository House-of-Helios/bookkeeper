#!/bin/bash
# Put the code on GitHub (House-of-Helios/bookkeeper), and only the code.
#
# The full history stays on this Mac. GitHub gets its own line of history on the local
# branch `public`: each run adds one commit holding this commit's files minus the private
# paths below, and pushes `public` to GitHub's `main`. Nothing from the private history,
# and nothing under a private path, ever enters `public` — it is built from a filtered
# tree, not from a merge.
#
# Usage:  bash scripts/publish.sh ["what changed"]      (scripts/release.sh calls it)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="House-of-Helios/bookkeeper"
# Working notes, research, reference images, retired scripts and the agent's own instructions.
PRIVATE=(_Plan _Research CLAUDE.md zerion.png $'Icon\r' scripts/_Past)

[ -z "$(git status --porcelain)" ] || { echo "❌ uncommitted changes — commit first"; exit 1; }
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"

INDEX=$(mktemp); trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree HEAD
for p in "${PRIVATE[@]}"; do git rm -r -q --cached --ignore-unmatch -- "$p"; done
TREE=$(git write-tree)
unset GIT_INDEX_FILE

# XMRange's check-publish, cut to this repo: no home path or user name, no e-mail address,
# no AI attribution line, no mention of the retired private update road, in any text that
# is about to leave. Counts and names only.
ME="$(id -un)"
scan() { # <label> <text> → prints findings, returns 1 on any
  local label="$1" text="$2" n bad=0
  grep -qI . <<<"$text" || return 0                         # binary
  n=$(grep -cE "/Users/$ME|$ME" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "❌ $label: $n line(s) with this Mac's user name or home path"; bad=1; }
  n=$({ grep -oiE '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' <<<"$text" || true; } | { grep -viE '@example\.(com|org)$|^git@' || true; } | sort -u | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && { echo "❌ $label: $n e-mail address(es)"; bad=1; }
  n=$(grep -ciE "co-author""ed-by|generated with \[?claude" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "❌ $label: $n attribution line(s)"; bad=1; }
  n=$(grep -ciE "_Shipping""Port" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "❌ $label: $n mention(s) of the private update road"; bad=1; }
  n=$(grep -cE "(github_pat|gh[pousr])_[A-Za-z0-9_]{20,}" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "❌ $label: $n GitHub token(s)"; bad=1; }
  return $bad
}
scan_tree() { # <tree-ish> → 1 on any finding or unreadable file
  local t="$1" bad=0 mode type obj path
  while IFS= read -r -d '' line; do
    read -r mode type obj <<<"${line%%$'\t'*}"; path="${line#*$'\t'}"
    [ "$type" = blob ] || continue
    text=$(git cat-file blob "$obj") || { echo "❌ couldn't read $path"; bad=1; continue; }
    scan "$path" "$text" || bad=1
  done < <(git ls-tree -r -z "$t")
  return $bad
}

PARENT=$(git rev-parse -q --verify refs/heads/public || true)
if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
  echo "🐙 nothing new for GitHub"
else
  MSG="${1:-$(git log -1 --format=%s)}"
  # Checked before the branch moves: a failing tree never becomes `public`.
  { scan_tree "$TREE" && scan "commit message" "$MSG"; } || { echo "❌ privacy check failed — nothing published"; exit 1; }
  # One fixed name, no e-mail, on every public commit — never this Mac's git identity.
  COMMIT=$(GIT_AUTHOR_NAME="House of Helios" GIT_AUTHOR_EMAIL="" GIT_COMMITTER_NAME="House of Helios" GIT_COMMITTER_EMAIL="" \
    git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "$MSG")
  git update-ref refs/heads/public "$COMMIT"
  echo "🐙 public ← $(git rev-parse --short "$COMMIT") ($MSG)"
fi

# Everything not yet on GitHub, every commit of it: no private path, the scan clean.
git fetch -q origin main 2>/dev/null || true
RANGE=$(git rev-parse -q --verify origin/main >/dev/null && echo "origin/main..public" || echo "public")
for c in $(git rev-list "$RANGE"); do
  for p in "${PRIVATE[@]}"; do
    git ls-tree -r -z --name-only "$c" | tr '\0' '\n' | grep -q -e "^$p\$" -e "^$p/" && { echo "❌ $p is in $c"; exit 1; }
  done
  { scan_tree "$c" && scan "message of $c" "$(git log -1 --format=%B "$c")" && \
    scan "identity of $c" "$(git log -1 --format='%an %ae %cn %ce' "$c")"; } || { echo "❌ privacy check failed — nothing pushed"; exit 1; }
done

git push -q origin public:main
echo "✅ https://github.com/$REPO"
