# torizon-ab-manifest

`repo` manifest for the **OSTree-free A/B Torizon OS** variant (SWUpdate + RAUC
backends). It vendors the upstream Toradex manifest at a **pinned revision** and
overlays the "outside BSP", vendor-agnostic A/B layers, so a fresh checkout builds
the variant with **one command** and is **reproducible**.

## Build it yourself

```sh
mkdir torizon-ab && cd torizon-ab
repo init -u https://github.com/EstebanSannin/torizon-ab-manifest -b main \
          -m torizon-ab/tdx/release.xml
repo sync
# then: source setup-environment build, set DISTRO=torizon-ab|torizon-ab-rauc,
#       add the overlay layers to bblayers, and bitbake (see meta-torizon-ab).
```

`-m` picks the **vendor + channel**. Toradex boards (verdin-am62p, verdin-imx8mp,
genericx86-64) are `torizon-ab/tdx/…`.

## Layout

```
<root>                       ← vendored upstream tree (torizon/, bsp/, base/, tezi/, …)
                               pinned by scripts/update-upstream.sh → UPSTREAM.env
torizon-ab/                  ← OUR overlay (the only files we own)
  overlay.xml                ← meta-swupdate + meta-rauc + meta-torizon-ab (vendor-agnostic)
  <vendor>/<channel>.xml     ← include upstream <vendor>/<channel> + overlay.xml
    tdx/release.xml          ← Toradex boards, monthly/quarterly
    tdx/nightly.xml          ← Toradex boards, nightly (upstream integration)
    tdx/next.xml             ← Toradex boards, extint/master
scripts/update-upstream.sh   ← re-vendor upstream at a new pinned rev
UPSTREAM.env                 ← the pinned upstream URL/branch/SHA
```

### Channels (mirroring Toradex's manifest)

| Channel file  | Cadence            | Upstream source (post-restructure) |
|---------------|--------------------|-------------------------------------|
| `nightly.xml` | nightly            | `integration.xml`                   |
| `next.xml`    | extint/master      | `next.xml`                          |
| `release.xml` | monthly/quarterly  | `release.xml` (was `default.xml`)   |

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
