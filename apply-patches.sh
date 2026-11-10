#!/usr/bin/env bash
#
# apply-patches.sh - apply NX1 device tree patches onto the synced tree
#
# Run after `repo sync`, before `breakfast NX1`.
# Patches are applied with `git am` inside device/bluefox/NX1 so they land
# as real commits (Crave uploads local commits; uncommitted diffs are
# handled differently and are easier to lose).
#
# Idempotent: re-running skips patches already present by exact patch-id.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable so build.sh can invoke this script from the source root
# while the patches stay in the project directory.
SRC_ROOT="${SRC_ROOT:-$SCRIPT_DIR}"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/patches}"
DEVICE_DIR="${DEVICE_DIR:-$SRC_ROOT/device/bluefox/NX1}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }

if [[ ! -d "$DEVICE_DIR" ]]; then
  err "device tree not found at $DEVICE_DIR"
  echo "  run this from the LineageOS source root, after repo sync" >&2
  exit 1
fi

if ! git -C "$DEVICE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  err "$DEVICE_DIR is not a git repository"
  exit 1
fi

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [[ ${#patches[@]} -eq 0 ]]; then
  err "no patches found in $PATCH_DIR"
  exit 1
fi

log "found ${#patches[@]} patch(es) in $PATCH_DIR"

# Collect patch-ids already in the tree so re-runs are cheap and safe.
# A patch-id is a hash of the diff only, immune to subject rewrites
# performed by `git am`.
existing_ids="$(git -C "$DEVICE_DIR" log --format='%H' --all \
                  | while read -r c; do git -C "$DEVICE_DIR" show "$c" | git patch-id --stable; done \
                  | awk '{print $1}')"

applied=0; skipped=0; failed=0
failed_names=()

for p in "${patches[@]}"; do
  name="$(basename "$p")"
  printf '  %-52s ' "${name:0:52}"

  pid="$(git patch-id --stable < "$p" | awk '{print $1}')"

  if grep -qxF "$pid" <<<"$existing_ids"; then
    printf '%salready applied%s\n' "$YLW" "$RST"
    skipped=$((skipped + 1))
    continue
  fi

  if git -C "$DEVICE_DIR" am --3way --keep-cr "$p" >/tmp/nx1-patch.log 2>&1; then
    printf '%sapplied%s\n' "$GRN" "$RST"
    applied=$((applied + 1))
    existing_ids+=$'\n'"$pid"
  else
    printf '%sfailed%s\n' "$RED" "$RST"
    git -C "$DEVICE_DIR" am --abort >/dev/null 2>&1 || true
    failed=$((failed + 1))
    failed_names+=("$name")
    sed -n '1,6p' /tmp/nx1-patch.log | sed 's/^/      /'
  fi
done

echo
log "applied=$applied  skipped=$skipped  failed=$failed"

if [[ $failed -gt 0 ]]; then
  echo
  err "these patches did not apply:"
  printf '    %s\n' "${failed_names[@]}"
  echo
  echo "  Most likely cause: the device tree has moved on since these were" >&2
  echo "  written. Re-generate with:" >&2
  echo "    cd device/bluefox/NX1 && git format-patch ..." >&2
  echo "  The tree is clean (patches were aborted), so a partial state is" >&2
  echo "  not a concern." >&2
  exit 1
fi

# ---------------------------------------------------------------- verify

echo
log "verifying patched configuration"

fail=0
grep -q 'PRODUCT_SHIPPING_API_LEVEL := 37' "$DEVICE_DIR/device.mk" \
  && log "  shipping API level 37 (Android 17)" \
  || { warn "  shipping API level is not 37"; fail=1; }

grep -q 'zh_CN' "$DEVICE_DIR/lineage_NX1.mk" \
  && log "  zh_CN locale present" \
  || { warn "  zh_CN locale missing"; fail=1; }

[[ "$(tr -d '[:space:]' < "$DEVICE_DIR/lineage.dependencies")" == "[]" ]] \
  && log "  lineage.dependencies neutralised" \
  || { warn "  lineage.dependencies still populated"; fail=1; }

if [[ $fail -eq 1 ]]; then
  err "configuration verification failed"
  exit 1
fi

echo
log "done - next:"
echo "    source build/envsetup.sh"
echo "    breakfast NX1"
