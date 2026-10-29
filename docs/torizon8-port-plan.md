# Torizon OS 8 ("wrynose") port — plan

Status: **verdin-imx8mp × SWUpdate and × RAUC ported and hardware-validated**
(local + Torizon Cloud) on the integration channel (2026-10-28), SWUpdate re-run
after the shared handler fixes. **genericx86-64 × both backends validated in
QEMU** (local + Torizon Cloud, 2026-10-29). **CI builds the full 6-combo matrix
on 8**; it publishes only the validated combos. Torizon 7 (scarthgap-7.x.y)
stays the fallback baseline. Next: verdin-am62p on hardware.

## Hardware validation — verdin-imx8mp × SWUpdate (Verdin iMX8M Plus on Dahlia)

All on real hardware, driven headless (power/recovery control + serial):

| Step | Result |
|------|--------|
| Flash (uuu, no Tezi) | wic → eMMC user area, imx-boot → boot0, BOOT_ACK=1 |
| First boot | U-Boot 2027.01-rc1 → A/B boot.scr → slot A, Linux 6.18, login |
| A→B update | `swupdate_actions.sh install` (aktualizr contract) → `need-completion` → auto-reboot into B; slot B ext4 UUID == payload UUID |
| B→A update | same, opposite direction; greenboot commits the update at boot |
| `complete-install` | `ok` after a good update; `failed: rolled back` after a rollback |
| Rollback | failing required health check on B → 3 attempts → `Bootlimit (3) exceeded` → altbootcmd → slot A |
| Torizon Cloud, good update | provision → upload (`POST /packages`, 187 MB) → launch → aktualizr → slot switch → cloud **Completed / UpToDate** |
| Torizon Cloud, bad update | rollback-test image → 3 failed boots → back to the good slot → cloud **`success: false`, "rootfs update failed; rolled back"** |

## Hardware validation — verdin-imx8mp × RAUC

| Step | Result |
|------|--------|
| Build | green after following meta-rauc to `/usr/lib/rauc` |
| Flash + first boot | slot A, `rauc.slot=A`, env seeded (incl. `altbootcmd`) |
| Local A→B | `rauc_actions.sh install` → B booted, both slots good, `complete-install` ok |
| Cloud, good bundle | **Completed / UpToDate** |
| Cloud, bad bundle | 3 failed boots → bootlimit → altbootcmd → old slot → cloud **`success: false`, rolled back** (also on a board with an older `boot.scr`) |

The first cloud bad-bundle run failed validation: no rollback, and the cloud got
**success** for the broken update. Fixed in meta-torizon-ab (both backends): the
handlers confirm only after greenboot passed the boot; the RAUC trial is mirrored
in `upgrade_available` so greenboot reboots a failed trial; `altbootcmd` is
guaranteed; U-Boot env variables are tested by value. Details in meta-torizon-ab
`docs/updates-and-rollback.md`. **The SWUpdate handler changed after its
validation; it was re-run on hardware (below).**

## SWUpdate re-test with the shared fixes (verdin-imx8mp)

| Step | Result |
|------|--------|
| Fresh flash + first boot | slot A, `altbootcmd` seeded, no U-Boot env errors |
| Cloud, good `.swu` | **Completed / UpToDate** |
| Cloud, bad `.swu` | first failed boot held on purpose (greenboot auto-reboot masked): `complete-install` → `need-completion`, trial kept armed; then attempts 2–3 → bootlimit → altbootcmd → old slot → cloud **`success: false`, rolled back** |

Why aktualizr confirmed the failed RAUC trial boot: aktualizr normally does not
start on a failed boot (the health check is `RequiredBy=boot-complete.target`),
but stock Torizon's `redboot-auto-reboot` starts it with `--ignore-dependencies`
when the boot failed and `upgrade_available` is not 1 ("update not in progress,
device requires intervention"). The RAUC trial did not set the flag, so that path
ran and the old handler confirmed. Reproduced and confirmed on the board.

## QEMU validation — genericx86-64 (both backends)

QEMU/KVM with OVMF, virtio disk, user-mode networking. Access injected at runtime
by `tests/hardware/enable-access.sh` on the serial pty (image stays pristine).

| Step | SWUpdate | RAUC |
|------|----------|------|
| Fresh image, first boot | slot A | slot A |
| Local A→B (`*_actions.sh` contract) | B booted, `complete-install` ok | B booted, both slots good, `complete-install` ok |
| Cloud, good payload (1.1 GB) | **Completed / UpToDate** | **Completed / UpToDate** |
| Cloud, bad payload | 3 failed boots → bootlimit → slot A → cloud **`success: false`, rolled back** | failed trial rebooted → GRUB falls back to A → cloud **`success: false`, rolled back** |

The first RAUC bad-payload run did **not** roll back: greenboot's
`redboot-auto-reboot` reads the trial flag with `fw_printenv`, which the x86 RAUC
image lacked ("command not found" → "update not in progress"), so it never
rebooted the failed trial. Fixed in meta-torizon-ab: the grubenv
`fw_printenv`/`fw_setenv` wrappers moved to `grubenv-fw-utils` (both x86
backends) and the RAUC handler sets `upgrade_available` there too.

Notes from the runs:
- x86 payloads are **1.1 GB** (7: 792 MB). 1.8 GB of the 2.2 GB rootfs is
  `linux-firmware`, installed for genericx86-64 by meta-torizon-bsp's
  `torizon-image-machine` class.
- aktualizr keeps the last payload in `/var/sota/storage/rootfs/` after
  installing it, so the data partition needs room for two payloads plus the
  download. A run with a leftover 1.1 GB test file in `/var/tmp` filled the 3.8 GB
  data partition: the payload reached the handler truncated even though the
  download reported success; RAUC rejected it (bad signature size), nothing was
  installed.
- Torizon Cloud: two package uploads at the same time left one of them out of the
  Image repo targets metadata (listed by `GET /packages`, yet aktualizr reports
  "No matching target in Image repo Targets metadata"). Uploading one at a time
  works.
- The 1.1 GB uploads through the REST API took ~44 s each (`curl -T`; `curl
  --data-binary @file` runs out of memory at that size).

## CI on Torizon OS 8

`workflow_dispatch` on `port/torizon8`, integration channel, all 6 combos green.
One tree per manifest branch + vendor under `AB_TREES` (must not sit inside an
older single-tree repo client). Every combo builds; only the combos listed in the
workflow's `VALIDATED` are published, as pre-releases ("preview").

Flashing note: erase the whole **boot0** before writing imx-boot. The U-Boot env
lives at its end; a previous image's env survives otherwise and the new U-Boot
uses it (here: `booti` failed, `kernel_comp_addr_r` missing).

## Found while porting (worth reporting upstream)

- tdx `release.xml` pins a meta-torizon-bsp whose bblayers template still lists
  the abandoned `meta-toradex-distro` → build the integration channel.
- The manifest pins meta-updater `c73c905`; its `bootimg_sota_efi` wic plugin
  imports `oe.path`, which wrynose's standalone wic lacks, so **every wic image
  fails**. Fixed upstream in `23b4e41`; our overlay overrides the pin until then.
- greenboot's task runners start before udev creates the U-Boot env device
  (`/dev/emmc-boot0`): stock `00_cleanup_uboot_vars.sh` fails with "Cannot
  initialize environment" yet reports SUCCESS. Fixed here with a drop-in that
  waits for the `fw_env.config` devices (`torizon-ab-ubootenv-wait`).
- meta-torizon-bsp's `0001-rules-whitelist-hd-devices.patch` (genericx86-64)
  no longer applies to systemd 259 (new `rbd*|zram*|ublkb*` entries) → systemd
  `do_patch` fails. Rebased copy carried in meta-torizon-ab until upstream does.
- meta-torizon-bsp sets `CONFIG_KERNEL_LZ4` for linux-yocto (`torizon.cfg`) but
  adds `lz4-native` only to linux-intel → genericx86-64 bzImage fails with "lz4:
  not found". meta-torizon-ab adds the dependency until upstream does.
- `systemd-networkd-wait-online` ends up enabled (meta-torizon's postinst
  disable does not stick on wrynose) and fails → system `degraded`.

## Open points

- `os-release` VERSION does not change between builds (the package is reused
  from sstate), so two different images report the same version; the slot UUID
  is the reliable discriminator meanwhile.
- `kernel-devsrc` left out (fixed 1536 MiB slots).

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
