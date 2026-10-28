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
#   AB_ROOT         base dir for the persistent trees, one per manifest branch
#                   and vendor: $AB_ROOT/<branch>/<vendor>   (default: ~/code/ab-ci)
#   SHARED_CACHES   dir holding downloads/ + sstate-cache (default: ~/code/torizon-os)
#   MANIFEST_URL / MANIFEST_BRANCH                       (default: this repo on GitHub / main)
#   CROPS_IMAGE                                          (default: torizon/crops:wrynose-8.x.y)
#   OUT_DIR         where to place published artifacts   (default: <tree>/artifacts/<machine>-<backend>)
set -euo pipefail

# Resolve the script's own dir NOW, before any cd (ci/conf lives next to it).
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MACHINE="${MACHINE:?set MACHINE}"
DISTRO="${DISTRO:?set DISTRO (torizon-ab | torizon-ab-rauc)}"
CHANNEL="${CHANNEL:-release}"
VENDOR="${VENDOR:-tdx}"
AB_ROOT="${AB_ROOT:-$HOME/code/ab-ci}"
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
TREE="$AB_ROOT/${MANIFEST_BRANCH//\//-}/$VENDOR"
OUT_DIR="${OUT_DIR:-$TREE/artifacts/${MACHINE}-${BACKEND}}"
MANIFEST_XML="torizon-ab/${VENDOR}/${CHANNEL}.xml"

echo "== torizon-ab CI build =="
echo "   MACHINE=$MACHINE DISTRO=$DISTRO (backend=$BACKEND) channel=$CHANNEL"
echo "   manifest=$MANIFEST_BRANCH:$MANIFEST_XML tree=$TREE build_dir=$BUILD_DIR caches=$SHARED_CACHES"

# 1) sync the manifest tree (init once, then sync to the pinned/tip revs)
mkdir -p "$TREE"
cd "$TREE"
if [ ! -d .repo ]; then
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" -m "$MANIFEST_XML"
else
  repo init -m "$MANIFEST_XML" >/dev/null   # allow channel switch between runs
fi
repo sync -j"$(nproc)" -c

# 2) build in crops, reusing shared caches. Generate the conf from the synced
#    tree (do NOT rely on oe-init defaults — those are poky and miss the Toradex +
#    overlay layers).
"$CI_DIR/mkconf.sh" "$TREE" "$BUILD_DIR" "$CHANNEL"

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
  "

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
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# checksums (payload + image + bmap; not the metadata file itself)
( cd "$OUT_DIR" && sha256sum -- * 2>/dev/null | grep -v ' metadata.env$' > SHA256SUMS )
echo "== artifacts in $OUT_DIR =="
ls -lhL "$OUT_DIR"
