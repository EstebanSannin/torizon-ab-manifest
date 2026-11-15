#!/usr/bin/env bash
# CI build entrypoint for the torizon-ab manifest.
#
# Syncs the manifest tree at a channel, builds one MACHINE x DISTRO in the crops
# container (reusing shared downloads/sstate), then collects the publishable
# artifacts into $OUT_DIR: the OTA payload (.raucb|.swu), the flashable image
# compressed (.wic.xz + .bmap), and SHA256SUMS.
#
# Designed for a self-hosted runner, but is plain bash + docker so it can
# run anywhere with the crops image + network.
#
# Required env:
#   MACHINE   e.g. genericx86-64 | verdin-am62p | verdin-imx8mp
#   DISTRO    torizon-ab (SWUpdate) | torizon-ab-rauc (RAUC)
# Optional env (defaults suit a self-hosted build host):
#   CHANNEL         release | integration | next       (default: release)
#   VENDOR          manifest vendor dir (torizon-ab/<vendor>/) (default: tdx)
#   AB_TREES        base dir for the persistent trees, one per manifest branch
#                   and vendor: $AB_TREES/<branch>/<vendor>  (default: ~/code/ab-trees)
#                   Must not sit inside a repo client (e.g. an older single-tree
#                   AB_ROOT checkout): repo would reuse that client instead.
#   SHARED_CACHES   dir holding downloads/ + sstate-cache (default: ~/code/torizon-os)
#   MANIFEST_URL / MANIFEST_BRANCH                       (default: this repo on GitHub / main)
#   CROPS_IMAGE                                          (default: torizon/crops:wrynose-8.x.y)
#   OUT_DIR         where to place published artifacts   (default: <tree>/artifacts/<machine>-<backend>)
#   REPORT_DIR      where to write the build report       (default: $OUT_DIR.report)
#   FALLBACK        auto (default) | off. On a floating channel (integration,
#                   next), a failed build is retried with the upstream layers at
#                   the pins of the last good build of this combo and our layer
#                   at the revision just synced. If that passes, upstream drift
#                   broke the tip: the build is kept (PINS=last-good in
#                   metadata.env) and the report says what changed. Recipes that
#                   follow AUTOREV under use-head-next still float.
#
# The report ($REPORT_DIR) holds status.env (RESULT=ok|fallback|failed),
# errors.txt (the failing tasks and errors of the tip build) and
# upstream-delta.txt (the layers that moved since the last good build).
set -euo pipefail

# Resolve the script's own dir NOW, before any cd (ci/conf lives next to it).
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MACHINE="${MACHINE:?set MACHINE}"
DISTRO="${DISTRO:?set DISTRO (torizon-ab | torizon-ab-rauc)}"
CHANNEL="${CHANNEL:-release}"
VENDOR="${VENDOR:-tdx}"
AB_TREES="${AB_TREES:-$HOME/code/ab-trees}"
SHARED_CACHES="${SHARED_CACHES:-$HOME/code/torizon-os}"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/EstebanSannin/torizon-ab-manifest}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-main}"
CROPS_IMAGE="${CROPS_IMAGE:-torizon/crops:wrynose-8.x.y}"

case "$DISTRO" in
  torizon-ab-rauc) BACKEND=rauc;     PAYLOAD_TARGET=torizon-ab-bundle; PAYLOAD_GLOB="*.raucb" ;;
  torizon-ab)      BACKEND=swupdate; PAYLOAD_TARGET=torizon-ab-swu;    PAYLOAD_GLOB="*.swu"   ;;
  *) echo "unknown DISTRO: $DISTRO" >&2; exit 2 ;;
esac
BUILD_DIR="build-${MACHINE}-${BACKEND}"
# One tree per manifest branch + vendor: they pin different layer sets (and
# different Yocto series across branches), so sharing one tree would churn every
# checkout and reuse build dirs across series. Caches stay shared.
TREE="$AB_TREES/${MANIFEST_BRANCH//\//-}/$VENDOR"
OUT_DIR="${OUT_DIR:-$TREE/artifacts/${MACHINE}-${BACKEND}}"
REPORT_DIR="${REPORT_DIR:-$OUT_DIR.report}"
FALLBACK="${FALLBACK:-auto}"
MANIFEST_XML="torizon-ab/${VENDOR}/${CHANNEL}.xml"
# Pins of the last good build, per combo. Kept next to the tree, not in it: a
# fresh tree must not lose them, and repo must not see them.
STATE_DIR="$(dirname "$TREE")/state"
LAST_GOOD="$STATE_DIR/last-good-${VENDOR}-${CHANNEL}-${MACHINE}-${BACKEND}.xml"
LAST_GOOD_DATE="$([ -f "$LAST_GOOD" ] && date -u -r "$LAST_GOOD" +%Y-%m-%dT%H:%M:%SZ || true)"

echo "== torizon-ab CI build =="
echo "   MACHINE=$MACHINE DISTRO=$DISTRO (backend=$BACKEND) channel=$CHANNEL"
echo "   manifest=$MANIFEST_BRANCH:$MANIFEST_XML tree=$TREE build_dir=$BUILD_DIR caches=$SHARED_CACHES"

# 1) sync the manifest tree (init once, then sync to the pinned/tip revs)
mkdir -p "$TREE" "$STATE_DIR"
rm -rf "$REPORT_DIR"; mkdir -p "$REPORT_DIR"
cd "$TREE"
d="$(dirname "$TREE")"
while [ "$d" != / ]; do
  [ -d "$d/.repo" ] && { echo "tree $TREE is inside the repo client $d; set AB_TREES elsewhere" >&2; exit 2; }
  d="$(dirname "$d")"
done
if [ ! -d .repo ]; then
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" -m "$MANIFEST_XML"
else
  repo init -m "$MANIFEST_XML" >/dev/null   # allow channel switch between runs
fi

# Sync to the channel's manifest, or to a full pinned one given as $1 (absolute).
sync_tree() {
  repo sync -j"$(nproc)" -c ${1:+-m "$1"}
}

# 2) build in crops, reusing shared caches. Generate the conf from the synced
#    tree (do NOT rely on oe-init defaults — those are poky and miss the Toradex +
#    overlay layers). The bitbake output goes to $1 as well.
build() {
  "$CI_DIR/mkconf.sh" "$TREE" "$BUILD_DIR" "$CHANNEL" || return
  docker run --rm --name "abci-$$" \
    -v "$TREE:/workdir" \
    -v "$SHARED_CACHES/downloads:/dl" \
    -v "$SHARED_CACHES/sstate-cache:/sstate" \
    --workdir=/workdir "$CROPS_IMAGE" bash -c "
      set -e
      export MACHINE='$MACHINE' DISTRO='$DISTRO' EULA=1
      source /workdir/layers/openembedded-core/oe-init-build-env /workdir/$BUILD_DIR >/dev/null
      bitbake torizon-minimal-ab $PAYLOAD_TARGET
      # resolve DEPLOY_DIR_IMAGE (TI redirects to deploy-ti/, x86 uses tmp/deploy)
      bitbake -e torizon-minimal-ab | sed -n 's/^DEPLOY_DIR_IMAGE=\"\(.*\)\"/\1/p' > /workdir/$BUILD_DIR/.deploydir
    " 2>&1 | tee "$1"
  return "${PIPESTATUS[0]}"
}

# The failing tasks and errors of a bitbake log, for the report.
errors_of() {
  grep -E '^(ERROR|WARNING): |^Summary: |^  /workdir/.*:do_|^\| .*([Ee]rror|cannot|No such|not found|fatal)' "$1" |
    grep -v 'Logfile of failure stored in' | head -80
}

# One line per project whose revision differs between two pinned manifests, with
# the commits in between when the tree has them.
upstream_delta() {
  python3 -I - "$1" "$2" <<'PYEOF' | while read -r path old new; do
import sys, xml.etree.ElementTree as ET
def pins(f):
    return {p.get('path') or p.get('name'): p.get('revision') for p in ET.parse(f).getroot().iter('project')}
old, new = pins(sys.argv[1]), pins(sys.argv[2])
for path in sorted(set(old) | set(new)):
    if old.get(path) != new.get(path):
        print(path, old.get(path) or '-', new.get(path) or '-')
PYEOF
    echo "$path ${old:0:12} -> ${new:0:12}"
    if [ "$old" != - ] && [ "$new" != - ]; then
      git -C "$TREE/$path" log --oneline --no-decorate -20 "$old..$new" 2>/dev/null | sed 's/^/    /'
    fi
  done
}

report() {   # report <result> [pins]
  cat > "$REPORT_DIR/status.env" <<EOF
MACHINE=$MACHINE
BACKEND=$BACKEND
CHANNEL=$CHANNEL
RESULT=$1
PINS=${2:-tip}
LAST_GOOD_DATE=$LAST_GOOD_DATE
EOF
}

PINS=tip
sync_tree
if ! build "$REPORT_DIR/bitbake-tip.log"; then
  errors_of "$REPORT_DIR/bitbake-tip.log" > "$REPORT_DIR/errors.txt"
  repo manifest -r -o "$REPORT_DIR/tip-pins.xml" >/dev/null 2>&1 || true
  case "$CHANNEL" in integration|next) floating=1 ;; *) floating=0 ;; esac
  if [ "$FALLBACK" != auto ] || [ "$floating" = 0 ] || [ ! -f "$LAST_GOOD" ]; then
    [ -f "$LAST_GOOD" ] && upstream_delta "$LAST_GOOD" "$REPORT_DIR/tip-pins.xml" > "$REPORT_DIR/upstream-delta.txt"
    report failed
    echo "== build failed (no fallback: FALLBACK=$FALLBACK channel=$CHANNEL last-good=$([ -f "$LAST_GOOD" ] && echo yes || echo none)) ==" >&2
    exit 1
  fi
  upstream_delta "$LAST_GOOD" "$REPORT_DIR/tip-pins.xml" > "$REPORT_DIR/upstream-delta.txt"
  # Last good upstream, our layer as just synced.
  ours="$(git -C layers/meta-torizon-ab rev-parse HEAD)"
  sed "/path=\"layers\/meta-torizon-ab\"/ s/revision=\"[0-9a-f]*\"/revision=\"$ours\"/" \
    "$LAST_GOOD" > "$REPORT_DIR/fallback-pins.xml"
  echo "== tip build failed; retrying with the last good upstream pins ($LAST_GOOD) =="
  PINS=last-good
  sync_tree "$REPORT_DIR/fallback-pins.xml"
  if ! build "$REPORT_DIR/bitbake-last-good.log"; then
    report failed last-good
    echo "== build failed on the last good upstream pins too: the breakage is ours ==" >&2
    exit 1
  fi
fi
repo manifest -r -o "$LAST_GOOD.new" && mv "$LAST_GOOD.new" "$LAST_GOOD"

DEPLOY="$(cat "$BUILD_DIR/.deploydir")"
DEPLOY="${DEPLOY/\/workdir/$TREE}"   # map container path back to host
echo "== deploy dir: $DEPLOY =="

# 3) collect + package artifacts
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
# Newest versioned file matching a glob. Versioned names carry a build timestamp,
# so the deploy dir accumulates one per build; the unversioned names are symlinks
# (skipped by -type f).
newest() { find "$DEPLOY" -maxdepth 1 -type f -name "$1" -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-; }
# OTA payload
payload="$(newest "$PAYLOAD_GLOB")"
[ -n "$payload" ] || { echo "no payload ($PAYLOAD_GLOB) in $DEPLOY" >&2; exit 3; }
cp "$payload" "$OUT_DIR/"
# flashable image: compress the sparse .wic (tiny once compressed) + keep bmap
wic="$(newest 'torizon-minimal-ab-*.wic')"
if [ -n "$wic" ]; then
  xz -T0 -c "$wic" > "$OUT_DIR/$(basename "$wic").xz"
  [ -f "$wic.bmap" ] && cp -L "$wic.bmap" "$OUT_DIR/"
fi

# GitHub rewrites '+' in release-asset names, which would desync them from
# SHA256SUMS. Pre-sanitize '+' -> '-' (matching the TAG) so names == checksums.
for f in "$OUT_DIR"/*; do
  b="$(basename "$f")"
  case "$b" in *+*) mv -- "$f" "$OUT_DIR/${b//+/-}" ;; esac
done

# build metadata (drives the Release tag/name + later builds.json).
# OS_VERSION is parsed from the .wic name: torizon-minimal-ab-<machine>-<version>.wic
OS_VERSION="unknown"
if [ -n "$wic" ]; then
  v="$(basename "$wic")"; v="${v#torizon-minimal-ab-${MACHINE}-}"; OS_VERSION="${v%.wic}"
fi
BUILD_ID="torizon-ab-${BACKEND}-${MACHINE}-${OS_VERSION}"
TAG="${BUILD_ID//+/-}"                      # '+' is awkward in a git tag/URL
cat > "$OUT_DIR/metadata.env" <<EOF
MACHINE=$MACHINE
BACKEND=$BACKEND
CHANNEL=$CHANNEL
OS_VERSION=$OS_VERSION
BUILD_ID=$BUILD_ID
TAG=$TAG
PINS=$PINS
LAST_GOOD_DATE=$LAST_GOOD_DATE
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# checksums (payload + image + bmap; not the metadata file itself)
( cd "$OUT_DIR" && sha256sum -- * 2>/dev/null | grep -v ' metadata.env$' > SHA256SUMS )
echo "== artifacts in $OUT_DIR =="
ls -lhL "$OUT_DIR"
[ "$PINS" = tip ] && report ok || report fallback last-good
