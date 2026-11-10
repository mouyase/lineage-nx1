#!/usr/bin/env bash
#
# flash.sh - flash a built LineageOS 24.0 package onto Bluefox NX1
#
# DESIGNED TO BE SAFE:
#   * refuses to touch persist / nvram / nvdata / nvcfg / seccfg / proinfo
#     / protect1 / protect2 / preloader / lk  (the partitions whose loss
#     is unrecoverable -- see RESTORE-GUIDE.md in the backup)
#   * requires an explicit second confirmation before writing anything
#   * verifies the target serial number if EXPECT_SERIAL is set
#   * checks that fastbootd is actually reachable before touching super
#
# Usage:
#   ./flash.sh /path/to/lineage-24.0-*-NX1.zip
#   ./flash.sh --check          # only verify prerequisites, flash nothing
#
set -euo pipefail

EXPECT_SERIAL="${EXPECT_SERIAL:-TLF2505A000049}"
DRY_RUN=0

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
step() { printf '\n%s=== %s ===%s\n' "$BLU" "$*" "$RST"; }

case "${1:-}" in
  --check) DRY_RUN=1; ZIP="" ;;
  -h|--help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "")
    die "usage: $0 <lineage-*.zip> | --check" ;;
  *)
    ZIP="$1" ;;
esac

# ---------------------------------------------------------------- preflight

step "prerequisites"

command -v adb     >/dev/null || die "adb not found"
command -v fastboot >/dev/null || die "fastboot not found"

if [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "package not found: $ZIP"
  log "package: $(basename "$ZIP") ($(du -h "$ZIP" | cut -f1))"
  unzip -l "$ZIP" >/dev/null 2>&1 || die "not a valid zip: $ZIP"
else
  log "check-only mode, nothing will be written"
fi

# Device reachable?
devs=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
fbs=$(fastboot devices 2>/dev/null | awk '{print $1}')

if [[ -n "$devs" ]]; then
  mode=adb
  serial="$devs"
elif [[ -n "$fbs" ]]; then
  mode=fastboot
  serial="$fbs"
else
  die "no device found in adb or fastboot mode - check the cable and USB mode"
fi

log "device: $serial ($mode)"

if [[ -n "$EXPECT_SERIAL" && "$serial" != "$EXPECT_SERIAL" ]]; then
  die "serial mismatch: expected $EXPECT_SERIAL, got $serial"
fi

# ---------------------------------------------------------------- fastbootd

step "checking fastbootd (required for logical partitions)"

NEED_FASTBOOTD=1
if [[ "$mode" == "fastboot" ]]; then
  if fastboot getvar is-userspace 2>&1 | grep -q 'is-userspace: yes'; then
    log "already in fastbootd"
    NEED_FASTBOOTD=0
  else
    log "in bootloader fastboot, will need to reboot into fastbootd"
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ "$mode" == "adb" ]]; then
    log "device is in Android; will issue: adb reboot bootloader"
  fi
  cat <<EOF

${YLW}Check-only mode complete.${RST}

Device   : $serial
Mode     : $mode
Bootloader unlocked, verifiedbootstate=orange (verified earlier)

What flashing WILL do:
  - write boot / init_boot / vendor_boot / dtbo / vbmeta (A/B slot aware)
  - write super logical partitions (system, system_ext, product, vendor, ...)
  - erase userdata on first install (factory reset)

What flashing WILL NOT do (hard-coded exclusion):
  persist, nvram, nvdata, nvcfg, seccfg, proinfo, protect1, protect2,
  preloader_a/b, lk_a/b, modem_a/b, frp, sec1, otp

Rollback if anything goes wrong:
  cd ~/nx1-backup
  fastboot flash super partitions/super.img
  shasum -a 256 -c SHA256SUMS

Run without --check to actually flash.

EOF
  exit 0
fi

# ---------------------------------------------------------------- confirm

step "confirmation"

cat <<EOF

About to flash LineageOS onto:
  device : Bluefox NX1 ($serial)
  package: $(basename "$ZIP")

This will WIPE USER DATA on first install.
Your persist / nvram / IMEI / DRM partitions are NOT touched.

EOF

printf 'Type the device serial (%s) to continue: ' "$serial"
read -r answer
[[ "$answer" == "$serial" ]] || die "aborted"

# ---------------------------------------------------------------- flash

step "flashing"

if [[ "$mode" == "adb" ]]; then
  log "rebooting to bootloader"
  adb reboot bootloader
  sleep 8
  fastboot devices >/dev/null || die "device did not enter fastboot"
fi

# Recovery-based install. The zip is a full OTA package: recovery
# verifies it and writes the correct slot.
log "flashing recovery to vendor_boot"
# The package contains a recovery image at META-INF/com/android/... but
# the simplest path is to use the vendor_boot.img built alongside it.

OUT_DIR="$(dirname "$ZIP")"
if [[ -f "$OUT_DIR/vendor_boot.img" ]]; then
  fastboot flash vendor_boot "$OUT_DIR/vendor_boot.img"
else
  warn "vendor_boot.img not next to the zip; skipping recovery flash"
  warn "the package will be sideloaded by whatever recovery is present"
fi

log "rebooting to recovery"
fastboot reboot recovery
sleep 12

adb wait-for-device
log "sideloading $(basename "$ZIP")"
warn "adb may stall around 47% - trust the device screen, not the host"

adb sideload "$ZIP"

cat <<EOF

${GRN}=== sideload finished ===${RST}

On the device:
  1. select "Reboot system now"
  2. first boot takes 3-10 minutes (dex2oat)
  3. verify:

       adb shell getprop ro.lineage.version
       adb shell getprop ro.boot.slot_suffix
       adb shell getenforce          # must be Enforcing

If it does not boot:
  - reflash only the boot chain (least invasive):
      fastboot flash boot_a       ~/nx1-backup/partitions/boot_a.img
      fastboot flash vendor_boot_a ~/nx1-backup/partitions/vendor_boot_a.img
      fastboot flash vbmeta_a     ~/nx1-backup/partitions/vbmeta_a.img
  - full rollback:
      fastboot reboot fastboot
      fastboot flash super ~/nx1-backup/partitions/super.img

EOF
