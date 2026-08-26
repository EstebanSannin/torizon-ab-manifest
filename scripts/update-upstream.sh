#!/usr/bin/env bash
# Vendor the Toradex manifest tree into this repo's root at a pinned revision.
#
# WHY: `repo`'s <include name="..."> resolves relative to the manifest-repo ROOT,
# so upstream's tree (torizon/, common-torizon/, bsp/, base/, tezi/, ...) must live
# at our root for our torizon-ab/<vendor>/<channel>.xml includes to work. This
# script copies upstream's tracked files to the root and records the exact SHA, so
# a checkout of THIS repo is reproducible and the upstream bump is one commit.
#
# Our own files (torizon-ab/, scripts/, README.md, UPSTREAM.env, .gitignore) are
# never touched.
#
# Usage:
#   scripts/update-upstream.sh                 # use rev from UPSTREAM.env
#   scripts/update-upstream.sh <git-rev>       # pin a new rev (updates UPSTREAM.env)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# shellcheck disable=SC1091
[ -f UPSTREAM.env ] && . ./UPSTREAM.env
UPSTREAM_URL="${UPSTREAM_URL:-https://git.toradex.com/toradex-manifest.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-scarthgap-7.x.y}"   # TODO: confirm the Torizon branch we build
REV="${1:-${UPSTREAM_REV:-}}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> cloning $UPSTREAM_URL ($UPSTREAM_BRANCH)"
git clone --quiet --branch "$UPSTREAM_BRANCH" "$UPSTREAM_URL" "$tmp/up"
if [ -n "$REV" ]; then
  git -C "$tmp/up" checkout --quiet "$REV"
fi
SHA="$(git -C "$tmp/up" rev-parse HEAD)"
echo ">> upstream at $SHA"

# Remove previously-vendored upstream files (everything except our own paths),
# then copy the pinned tree in. Keep it simple + explicit about what is ours.
OURS=(torizon-ab scripts README.md UPSTREAM.env .gitignore .git)
is_ours() { local p="$1"; for o in "${OURS[@]}"; do [ "$p" = "$o" ] && return 0; done; return 1; }

# Wipe old vendored dirs/files at root.
for p in *; do is_ours "$p" || rm -rf "$p"; done

# Copy upstream tracked files (excludes upstream's .git).
( cd "$tmp/up" && git archive HEAD ) | tar -x -C "$here"

# Record the pin.
cat > UPSTREAM.env <<EOF
# Pinned upstream manifest — edit via scripts/update-upstream.sh <rev>
UPSTREAM_URL="$UPSTREAM_URL"
UPSTREAM_BRANCH="$UPSTREAM_BRANCH"
UPSTREAM_REV="$SHA"
EOF

echo ">> vendored upstream @ $SHA"
echo ">> review 'git status', then commit:  git commit -am 'sync upstream @ ${SHA:0:12}'"
