#!/usr/bin/env bash
# CI build entrypoint for the torizon-ab manifest.
#
# Syncs the manifest tree at a channel, builds one MACHINE x DISTRO in the crops
# container (reusing shared downloads/sstate), then collects the publishable
# artifacts into $OUT_DIR: the OTA payload (.raucb|.swu), the flashable image
# compressed (.wic.xz + .bmap), and SHA256SUMS.
#
# Designed for a self-hosted runner on m920x, but is plain bash + docker so it can
# run anywhere with the crops image + network.
#
# Required env:
#   MACHINE   e.g. genericx86-64 | verdin-am62p | verdin-imx8mp
#   DISTRO    torizon-ab (SWUpdate) | torizon-ab-rauc (RAUC)
# Optional env (sane defaults for m920x):
#   CHANNEL         release | nightly | next           (default: release)
#   AB_ROOT         persistent tree dir                 (default: ~/code/ab-ci)
#   SHARED_CACHES   dir holding downloads/ + sstate-cache (default: ~/code/torizon-os)
#   MANIFEST_URL / MANIFEST_BRANCH                       (default: this repo on GitHub / main)
#   CROPS_IMAGE                                          (default: torizon/crops:scarthgap-7.x.y)
#   OUT_DIR         where to place published artifacts   (default: $AB_ROOT/artifacts/<machine>-<backend>)
set -euo pipefail

# Resolve the script's own dir NOW, before any cd (ci/conf lives next to it).
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MACHINE="${MACHINE:?set MACHINE}"
DISTRO="${DISTRO:?set DISTRO (torizon-ab | torizon-ab-rauc)}"
CHANNEL="${CHANNEL:-release}"
AB_ROOT="${AB_ROOT:-$HOME/code/ab-ci}"
SHARED_CACHES="${SHARED_CACHES:-$HOME/code/torizon-os}"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/EstebanSannin/torizon-ab-manifest}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-main}"
CROPS_IMAGE="${CROPS_IMAGE:-torizon/crops:scarthgap-7.x.y}"

case "$DISTRO" in
  torizon-ab-rauc) BACKEND=rauc;     PAYLOAD_TARGET=torizon-ab-bundle; PAYLOAD_GLOB="*.raucb" ;;
  torizon-ab)      BACKEND=swupdate; PAYLOAD_TARGET=torizon-ab-swu;    PAYLOAD_GLOB="*.swu"   ;;
  *) echo "unknown DISTRO: $DISTRO" >&2; exit 2 ;;
esac
BUILD_DIR="build-${MACHINE}-${BACKEND}"
OUT_DIR="${OUT_DIR:-$AB_ROOT/artifacts/${MACHINE}-${BACKEND}}"
MANIFEST_XML="torizon-ab/tdx/${CHANNEL}.xml"   # TODO: per-vendor manifest when non-tdx machines land

echo "== torizon-ab CI build =="
echo "   MACHINE=$MACHINE DISTRO=$DISTRO (backend=$BACKEND) channel=$CHANNEL"
echo "   tree=$AB_ROOT build_dir=$BUILD_DIR caches=$SHARED_CACHES"

# 1) sync the manifest tree (init once, then sync to the pinned/tip revs)
mkdir -p "$AB_ROOT"
cd "$AB_ROOT"
if [ ! -d .repo ]; then
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" -m "$MANIFEST_XML"
else
  repo init -m "$MANIFEST_XML" >/dev/null   # allow channel switch between runs
fi
repo sync -j"$(nproc)" -c

# 2) build in crops, reusing shared caches. Ship the known-good conf (do NOT rely
#    on oe-init defaults — those are poky and miss the Toradex + overlay layers).
mkdir -p "$BUILD_DIR/conf"
cp "$CI_DIR/conf/bblayers.conf" "$BUILD_DIR/conf/bblayers.conf"
cp "$CI_DIR/conf/local.conf"    "$BUILD_DIR/conf/local.conf"
# override the caches to the shared host dirs (mounted at /dl,/sstate)
printf 'DL_DIR = "/dl"\nSSTATE_DIR = "/sstate"\n' > "$BUILD_DIR/conf/auto.conf"

docker run --rm --name "abci-$$" \
  -v "$AB_ROOT:/workdir" \
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
DEPLOY="${DEPLOY/\/workdir/$AB_ROOT}"   # map container path back to host
echo "== deploy dir: $DEPLOY =="

# 3) collect + package artifacts
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
# OTA payload (follow symlink to the versioned file)
payload="$(ls -1 "$DEPLOY"/$PAYLOAD_GLOB 2>/dev/null | grep -vE '\.(sha256|txt)$' | head -1)"
[ -n "$payload" ] || { echo "no payload ($PAYLOAD_GLOB) in $DEPLOY" >&2; exit 3; }
cp -L "$payload" "$OUT_DIR/"
# flashable image: compress the sparse .wic (tiny once compressed) + keep bmap
wic="$(ls -1 "$DEPLOY"/torizon-minimal-ab-*.wic 2>/dev/null | grep -vE '\.(vmdk|vdi|bmap)$' | head -1 || true)"
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
