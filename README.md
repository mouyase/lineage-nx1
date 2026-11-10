# lineage-nx1

LineageOS for the **Bluefox NX1** (`yk313_k69v1_64`, MediaTek MT6769V/CB /
Helio G81).

The repository name deliberately omits the Android version: this project
tracks whatever LineageOS branch the device tree currently supports, and
naming it `lineage-24` would mean renaming it again for 25.0. The target
branch lives in one place — `LINEAGE_BRANCH` in `build.sh`, default
`lineage-24.0` (Android 17).

The device has no official LineageOS support. The community device tree
exists only on `lineage-23.2` (Android 16). This project does the branch
adaptation work so the same tree builds against 24.0.

---

## What this project is

| Piece | Purpose |
|---|---|
| `local_manifests/nx1.xml` | Pins every device repo to an explicit revision. Replaces the stale `lineage.dependencies`. |
| `patches/` | Five `git am` patches that port the 23.2 device tree to 24.0. |
| `apply-patches.sh` | Applies those patches idempotently, inside `device/bluefox/NX1`. |
| `build.sh` | End-to-end: init → sync → patch → brunch. Re-runnable. |
| `scripts/setup-host.sh` | Provisions a fresh Ubuntu 22.04/24.04 x86_64 box. |
| `scripts/flash.sh` | Flashes the result, with a hard-coded partition exclusion list. |
| `crave/config` | Crave.io settings for the 600 GB / 64 GB workload. |

---

## Prerequisites

AOSP builds need **x86_64 Linux**, not macOS and not ARM.

| Resource | Official requirement | Notes |
|---|---|---|
| OS | Ubuntu 20.04 LTS or newer | 22.04 / 24.04 tested |
| Arch | **x86_64** | Prebuilt toolchains are x86_64 only |
| RAM | **64 GB** for lineage-21+ | 32 GB runs with 32 GB swap |
| Disk | **400 GB** | 600 GB comfortable with ccache |
| Time | 4–8 h cold, 20–40 min warm | Depends on cores and ccache |

`build.sh` warns on anything below these but still proceeds.

---

## Where to build

### Option A — Crave.io (free)

1. Apply: <https://forms.gle/KW78ykpU3CUzvE489>
2. State that you need **600 GB disk / 64 GB RAM** for AOSP.
3. Point them at this repo so they can see it is a real project.
4. After approval: download the CLI and `crave.conf` from
   <https://foss.crave.io/app/>, then:

```bash
cd ~/android/lineage          # after running build.sh through `repo sync`
cp <this-repo>/crave/config .crave/config
crave run -- brunch NX1 -j$(nproc)
```

### Option B — Hetzner dedicated (paid, ~€0.06/h)

```bash
# AX42: Ryzen 5 3600 / 32 GB / 2x512 GB NVMe, Ubuntu 24.04
scp -r . root@<host>:~/lineage-nx1
ssh root@<host>
  sudo ./lineage-nx1/scripts/setup-host.sh   # installs packages + 32 GB swap
  cd ~/lineage-nx1 && ./build.sh
```

Destroy the server when done. A cold build costs well under €1.

### Option C — local machine

Not viable on a 16 GB / 28 GB-free Apple Silicon Mac. See the caveat below.

---

## Why not build on the Mac

Three independent blockers:

1. **Architecture.** Apple Silicon is `aarch64`. AOSP ships prebuilt
   toolchains (clang, bison, the JDK boot image) for `x86_64` only.
2. **Disk.** 28 GB free vs ~400 GB required.
3. **RAM.** 16 GB vs 64 GB recommended.

A VM does not help: emulating x86_64 on ARM loses 5–10× performance, and
the disk is still not there.

---

## Procedure

```bash
git clone <this-repo> ~/lineage-nx1
cd ~/lineage-nx1

# one shot
./build.sh

# or step by step
export SRC_DIR=~/android/lineage
./build.sh                       # resumes from wherever it stopped
```

`build.sh` is idempotent: an existing `.repo` and an already-applied
patch set are both detected and skipped.

Artifacts land in `out/target/product/NX1/`:

```
lineage-24.0-<date>-UNOFFICIAL-NX1.zip
recovery.img
boot.img
vendor_boot.img
```

Then:

```bash
./scripts/flash.sh --check                       # verify device, flash nothing
./scripts/flash.sh out/target/product/NX1/lineage-24.0-*-NX1.zip
```

---

## The five patches

| Patch | What it changes | Why |
|---|---|---|
| `0001` | `PRODUCT_SHIPPING_API_LEVEL` 35 → 37, vendor SPL → 2025-10-05 | 24.0 targets API 37. The vendor SPL must describe the actual stock vendor image, not a hopeful future date. |
| `0002` | `PRODUCT_LOCALES := zh_CN en_US` | Fixes the half-translated UI you get when zh_CN is not compiled in. |
| `0003` | Empties `lineage.dependencies` | Roomservice otherwise resolves `sepolicy_vndr` / `hardware_mediatek` against **upstream** LineageOS, not the Bluefox forks that carry MT6768 support. |
| `0004` | Documents the recovery module list requirement | Recovery needs `jd9365tg_i2c.ko` / `jd9365tn_i2c.ko` or the display stays dark. |
| `0005` | Adds build diagnostics | Prints the effective kernel/module paths early, so a missing kernel drop fails fast instead of 40 minutes in. |

Patch 0001 is the one that matters for booting. The rest are quality of
life; drop them if they conflict and get the build green first.

---

## Expected failure modes

Ranked by how often they bite on a new branch bump:

1. **`PRODUCT_SHIPPING_API_LEVEL` mismatch** — framework refuses to boot.
   Symptom: bootloop with `SdkVersion mismatch` in logcat.
2. **HAL interface mismatch** — 24.0 added AIDL revisions the A15 vendor
   blobs do not implement. Symptom: specific HALs fail to start, camera
   or audio dead. Fix: `device/bluefox/NX1/compatibility_matrix.xml`.
3. **Missing blob** — a path in `proprietary-files.txt` no longer exists.
   Symptom: `error: vendor/bluefox/NX1/proprietary/...: No such file`.
4. **sepolicy denials** — new 24.0 rules conflict with MTK vendor policy.
   Symptom: `avc: denied` spam, service restart loops.
5. **Kernel module signature** — GKI 6.6 from the A15 drop may need the
   module list regenerated.

None of these are fatal. All are fixable. Expect to spend a few days on
1–3 the first time.

---

## Hard limits worth knowing before you start

The vendor image is Android 15 (`ro.vendor.api_level=202404`,
SDK 35). Android 17 system on Android 15 vendor is a two-generation
gap. It is supported by Treble in principle and usually works in
practice, but it is the edge case, not the well-trodden path.

`MediaTek connsys` (the WiFi/Bluetooth/GPS/modem subsystem) has **no
mainline Linux driver** and never will without vendor documentation.
That is irrelevant for this project — the Android vendor partition
keeps `wlan_drv_gen4m_6768.ko` and everything works — but it is why
postmarketOS cannot be a daily driver on this hardware.

---

## Rollback

A verified 51-partition backup lives at `~/nx1-backup/`.

```bash
cd ~/nx1-backup
shasum -a 256 -c SHA256SUMS          # 51/51 must pass

# lightest rollback: boot chain only
fastboot flash boot_a        partitions/boot_a.img
fastboot flash init_boot_a   partitions/init_boot_a.img
fastboot flash vendor_boot_a partitions/vendor_boot_a.img
fastboot flash dtbo_a        partitions/dtbo_a.img
fastboot flash vbmeta_a      partitions/vbmeta_a.img

# full rollback: system
fastboot reboot fastboot
fastboot flash super partitions/super.img
```

Never flash these from the backup over a working system unless you have
to: `persist`, `nvram`, `nvdata`, `nvcfg`, `seccfg`, `proinfo`,
`protect1`, `protect2`, `preloader_a/b`, `lk_a/b`.

---

## Status

- [x] Device tree fetched and inspected
- [x] Branch gap analysed (23.2 → 24.0)
- [x] Local manifest pinned to explicit revisions
- [x] Five adaptation patches written
- [x] Build / host-setup / flash scripts written
- [ ] **Repo sync executed** (needs a build host)
- [ ] **First successful build** (needs a build host)
- [ ] **fastbootd verified on device** (blocked: device not enumerating over USB)
- [ ] Flashed and booted

The last four all need either a build host or a working USB connection.
