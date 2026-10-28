# Torizon OS 8 ("wrynose") port — plan

Status: **draft spec** for the dedicated port session. Torizon 7 (scarthgap-7.x.y)
is green and published; it stays the fallback baseline. Do **not** run a full 7
matrix — the next full build should be 8.

## Goal

Re-anchor the OSTree-free A/B variant (SWUpdate + RAUC, aktualizr generic
secondary) onto Torizon OS 8 and prove it end-to-end on real hardware, without
disturbing the working 7 pipeline.

**First target (agreed): `verdin-imx8mp` × SWUpdate, end-to-end on real HW**
(Dahlia + Verdin iMX8MP). SWUpdate on iMX8MP is our most-validated path
(M1–M4). Only after that boots + takes an A→B update do we fan out to the other
machines/backends.

## What is already done (no 8 work needed)

- The **restructured manifest** (option B: `base/ bsp/ common-torizon/ tdx/
  torizon/ …`, `default.xml`→`release.xml`) is already vendored in the 7 tree.
- Our overlay seam is small and isolated: `torizon-ab/overlay.xml` declares the
  three non-BSP layers once; every `torizon-ab/tdx/<channel>.xml` = one upstream
  `<include>` + the overlay `<include>`.

## The delta to re-anchor for 8

Grounded in the current files — these are the only places that change:

1. **Upstream pin** — `UPSTREAM.env` + `scripts/update-upstream.sh`
   - `UPSTREAM_BRANCH`: `scarthgap-7.x.y` → the 8 branch (TBC — user provides).
   - `UPSTREAM_REV`: pin the exact 8 rev we build.
   - `OURS=(torizon-ab ci .github docs scripts README.md UPSTREAM.env …)` — verify
     nothing we own collides with a renamed/moved upstream path under 8.

2. **Overlay layer pins** — `torizon-ab/overlay.xml`
   - `meta-swupdate`: scarthgap branch → the **wrynose/master**-compatible branch;
     re-pin to a tested rev. (master already targets wrynose per the overlay note.)
   - `meta-rauc`: same — scarthgap → wrynose-compatible branch + new pinned rev.
   - `meta-torizon-ab`: `main` → a wrynose-compatible branch (e.g. `port/torizon8`)
     until the port is proven, then pin a tag/SHA.

3. **Channel include path** — `torizon-ab/tdx/{release,integration,next}.xml` (renamed from nightly to mirror upstream)
   - Each still `<include>`s `torizon/default.xml` with a TODO to switch to the
     restructured entry point. Switch the one `<include>` line to whatever the 8
     rev actually ships (likely `torizon/tdx/<channel>.xml`). One-liner each.

4. **CI build conf** — `ci/conf/bblayers.conf` + `ci/conf/local.conf`
   - The BSP layer list may gain/lose/rename layers under 8's reorg + newer Yocto.
     Reconcile `BBLAYERS` against the 8 tree. `OEROOT`/paths may shift.
   - `LAYERSERIES_COMPAT` on meta-rauc/meta-swupdate/meta-torizon-ab must list the
     8 Yocto codename, or layer load is rejected (this is exactly what bit us going
     master→scarthgap before).

5. **`meta-torizon-ab` itself** — the real porting surface
   - Re-validate against 8's Yocto + BSP: the aktualizr generic-secondary bbappend,
     `uboot-ab`, the `:k3` / `:mx8mp-generic-bsp` overrides, the `*.wks` files, and
     the HWID. Newer Yocto/BSP is where class/override/recipe-API breaks appear.

## Confirmed facts (Torizon OS 8)

- **Upstream moved:** `github.com/torizon/manifest`, branch `wrynose-8.x.y`
  (was `git.toradex.com/toradex-manifest.git`). Vendored @ `5cc7ecd`.
- **Yocto series = `wrynose`** (oe-core/meta-oe/meta-yocto `upstream="wrynose"`,
  bitbake 2.18). `LAYERSERIES_COMPAT` must say `wrynose`.
- **Per-vendor entry points:** `torizon/<vendor>/{release,integration,next}.xml`
  for tdx, x86, nxp, ti, nvidia, mtk, syn; shared `base/` + `bsp/`
  (`pinned.xml` / `integration.xml`). genericx86-64 now has its own `x86` vendor.
- **Toradex layers consolidated:** `meta-toradex-torizon` → **`meta-torizon`**
  (prio 90), new **`meta-torizon-bsp`** (prio 91, machine includes +
  `setup-environment`), `meta-toradex-bsp/{meta-toradex-nxp,-ti,-bsp-common}`.
  BSP adds `meta-imx` (`meta-imx-ml`) and `meta-freescale-ml`.
  `conf/distro/include/common-torizon.inc` keeps its path.
- **meta-swupdate / meta-rauc** both have `wrynose` branches; the tdx manifest
  ships neither (meta-swupdate only under `syn`), so no path collision.
- **crops:** `torizon/crops:wrynose-8.x.y` exists.
- CI `bblayers.conf` is **generated** by `ci/mkconf.sh` from the pinned
  `meta-torizon-bsp/conf/template/bblayers.conf`, overlay layers in `EXTRALAYERS`
  (layers the template lists but the manifest doesn't fetch are dropped with a
  warning). `local.conf` template is unchanged from 7.
- **Build the integration channel.** Upstream's tdx `release.xml` still pins a
  meta-torizon-bsp 57 commits behind whose template lists the abandoned
  `meta-toradex-distro`; integration floats meta-torizon(-bsp) at tip.
  Integration/next builds add `DISTROOVERRIDES .= ":use-head-next"` + buildhistory
  (as upstream's `setup-environment` does).
- **Image content:** per-machine packages moved to meta-torizon-bsp's
  `torizon-image-machine` class (applied to every image via `IMAGE_CLASSES`);
  `alsa-ucm-conf-tdx` folded into oe-core `alsa-ucm-conf`; NXP kernel renamed
  `linux-toradex` → `linux-toradex-imx` (6.18); wks files must live in
  `files/wic/`; `meta-torizon-bsp` sits at priority 91.
- **Known deltas vs upstream torizon-base.inc:** no `kernel-devsrc` (fixed
  1536 MiB slots). The `tpm` DISTRO_FEATURES warning predates the port.

## Execution order (iMX8MP × SWUpdate first)

1. On a **`port/torizon8` branch** of both repos (keep `main`/release on 7):
   vendor the 8 rev (`update-upstream.sh <rev>`), set the overlay branches/pins,
   switch the channel include.
2. Reconcile `ci/conf` for 8; get `torizon-ab` (SWUpdate) for `verdin-imx8mp` to a
   clean **dry-run parse** (`bitbake -n`), then a full build.
3. **Flash + boot** on the Dahlia/Verdin iMX8MP (Tezi/recovery), confirm it comes
   up on slot A.
4. Build a second rootfs payload (`.swu`) and run an **A→B update** via the
   aktualizr generic secondary; confirm slot switch + boot on B + rollback.
5. Only then: port RAUC on iMX8MP, then the am62p variants; finally the full
   matrix on 8 and publish.

## HW validation loop (what access enables)

Dahlia + Verdin iMX8MP with: **serial console**, **network/SSH** to the board,
a **flash path** (Tezi/recovery), and ideally **power control** for unattended
reboot/recovery. This is also the first concrete brick of the M2 test infra
(see release-testing.md).

## Guardrails

- 7 stays green and published; all 8 work on `port/torizon8` branches + a
  dedicated channel — nothing merges to 7's `main` until 8 is validated.
- Keep every overlay/layer rev **pinned** (reproducibility) once a build is good.
- No host paths / IPs / device IDs in committed files (brand + privacy rules).
