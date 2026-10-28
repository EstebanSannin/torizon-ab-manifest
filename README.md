# torizon-ab-manifest

`repo` manifest for the **OSTree-free A/B Torizon OS** variant (SWUpdate + RAUC
backends). It vendors the upstream Torizon manifest (`github.com/torizon/manifest`)
at a **pinned revision** and overlays the "outside BSP", vendor-agnostic A/B
layers, so a fresh checkout builds the variant with **one command** and is
**reproducible**.

## Build it yourself

```sh
mkdir torizon-ab && cd torizon-ab
repo init -u https://github.com/EstebanSannin/torizon-ab-manifest -b main \
          -m torizon-ab/tdx/integration.xml
repo sync
# conf: upstream's bblayers template + the overlay layers (what CI uses)
.repo/manifests/ci/mkconf.sh "$PWD" build integration
# then, in the crops container (tree mounted at /workdir):
#   MACHINE=verdin-imx8mp DISTRO=torizon-ab|torizon-ab-rauc
#   source layers/openembedded-core/oe-init-build-env build
#   bitbake torizon-minimal-ab torizon-ab-swu   # or torizon-ab-bundle for RAUC
```

For Torizon OS 8 build the **integration** channel: upstream's `release.xml`
still pins pre-restructure revisions.

`-m` picks the **vendor + channel**. Toradex boards (verdin-am62p, verdin-imx8mp,
genericx86-64) are `torizon-ab/tdx/…`.

## Layout

```
<root>                       ← vendored upstream tree (torizon/<vendor>/, bsp/, base/)
                               pinned by scripts/update-upstream.sh → UPSTREAM.env
torizon-ab/                  ← OUR overlay (the only files we own)
  overlay.xml                ← meta-swupdate + meta-rauc + meta-torizon-ab (vendor-agnostic)
  <vendor>/<channel>.xml     ← include upstream torizon/<vendor>/<channel>.xml + overlay.xml
    tdx/release.xml          ← Toradex boards (and genericx86-64), upstream pinned revs
    tdx/integration.xml      ← Toradex boards, upstream floating revs
    tdx/next.xml             ← Toradex boards, upstream next
ci/                          ← CI build: build.sh, mkconf.sh (generates the build conf)
scripts/update-upstream.sh   ← re-vendor upstream at a new pinned rev
UPSTREAM.env                 ← the pinned upstream URL/branch/SHA
```

### Channels (mirroring the Torizon manifest)

Our tree mirrors upstream's 1:1: `torizon-ab/<vendor>/<channel>.xml` includes
`torizon/<vendor>/<channel>.xml` — same vendor, same channel name.

| Channel file      | Upstream source               | Notes                                    |
|-------------------|-------------------------------|------------------------------------------|
| `release.xml`     | `torizon/<vendor>/release.xml`     | pinned revs                         |
| `integration.xml` | `torizon/<vendor>/integration.xml` | floating revs; builds add `use-head-next` |
| `next.xml`        | `torizon/<vendor>/next.xml`        | floating revs; builds add `use-head-next` |

### Adding a vendor (Jetson/NVIDIA, NXP FRDM, Renesas, …)

Because our layers are vendor-agnostic, a new vendor is a **3-line file** per
channel that includes upstream's vendor+channel manifest + `torizon-ab/overlay.xml`
— nothing duplicated. This mirrors Toradex's move to treat everything as
"outside BSP" (`torizon/<vendor>/<channel>.xml`, tdx as just another vendor).

## Why vendor upstream at the root?

`repo`'s `<include name="…">` resolves relative to the manifest-repo **root**, and
upstream's own manifests `<include name="base/pinned.xml"/>` etc. — so the upstream
tree must sit at our root for our includes to compose. `scripts/update-upstream.sh`
copies the tracked upstream files to the root and records the exact SHA in
`UPSTREAM.env`; our `torizon-ab/` files are never touched, so bumping upstream is a
single, conflict-free commit.

```sh
scripts/update-upstream.sh <git-rev>   # pin a new upstream rev
git commit -am "sync upstream @ <sha>"
```

## Status

**Scaffold / DRAFT.** Pending: confirm the upstream Torizon branch
(`UPSTREAM.env`), pin the three overlay revisions in `torizon-ab/overlay.xml`, run
the first vendoring, and validate `repo sync` + a build on the build host. The
`torizon/…` include paths carry a `TODO(upstream-restructure)` note to switch to
`torizon/tdx/<channel>.xml` once the vendored rev has the new layout.
