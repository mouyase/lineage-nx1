#!/usr/bin/env bash
#
# build.sh - full LineageOS 24.0 build pipeline for Bluefox NX1
#
# Stages:
#   1. repo init + sync (Android 17 base)
#   2. install local manifest (device tree + vendor + kernels)
#   3. sync device repos
#   4. apply device tree patches (23.2 -> 24.0 adaptation)
#   5. breakfast / brunch
#
# Safe to re-run: each stage checks whether it already completed.
#
# Environment overrides:
#   LINEAGE_BRANCH   default lineage-24.0
#   DEVICE           default NX1
#   SRC_DIR          default $HOME/android/lineage
#   JOBS             default nproc
#   SYNC_THREADS     default 8
#   CCACHE_SIZE      default 100G
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-24.0}"
DEVICE="${DEVICE:-NX1}"
SRC_DIR="${SRC_DIR:-$HOME/android/lineage}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
SYNC_THREADS="${SYNC_THREADS:-8}"
CCACHE_SIZE="${CCACHE_SIZE:-100G}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
step() { printf '\n%s=== %s ===%s\n' "$BLU" "$*" "$RST"; }
log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

step "preflight"

command -v repo >/dev/null 2>&1 || die "repo not installed. See scripts/setup-host.sh"
command -v git  >/dev/null 2>&1 || die "git not installed"

if [[ "$(uname -s)" == "Darwin" ]]; then
  warn "building on macOS (Apple Silicon?) - AOSP requires x86_64 Linux"
  warn "prebuilt toolchains are x86_64-only; expect failure"
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  warn "host arch is $(uname -m), not x86_64 - prebuilt toolchains will not run"
fi

avail_gb=$(df -Pk "$(dirname "$SRC_DIR")" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}')
if [[ -n "${avail_gb:-}" && "$avail_gb" -lt 400 ]]; then
  warn "only ${avail_gb} GB free at $(dirname "$SRC_DIR"); AOSP needs ~400 GB"
fi

mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$mem_gb" -gt 0 && "$mem_gb" -lt 32 ]]; then
  warn "only ${mem_gb} GB RAM; lineage-24.0 wants 64 GB (32 GB works with heavy swap)"
fi

# ---------------------------------------------------------------- 1. init

step "1/5 repo init ($LINEAGE_BRANCH)"

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

if [[ -d .repo ]]; then
  log "existing .repo found, skipping init"
  current=$(git -C .repo/manifests rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  log "current manifest branch: $current"
  [[ "$current" == "$LINEAGE_BRANCH" ]] || warn "manifest branch is $current, expected $LINEAGE_BRANCH"
else
  log "initialising $LINEAGE_BRANCH"
  repo init -u https://github.com/LineageOS/android.git \
            -b "$LINEAGE_BRANCH" \
            --git-lfs --no-clone-bundle
fi

# ---------------------------------------------------------------- 2. manifest

step "2/5 install local manifest"

mkdir -p .repo/local_manifests
cp "$SCRIPT_DIR/local_manifests/nx1.xml" .repo/local_manifests/nx1.xml
log "installed .repo/local_manifests/nx1.xml"

# ---------------------------------------------------------------- 3. sync

step "3/5 repo sync (this is the long one: ~200 GB)"

if [[ -f .repo/project.list ]] && [[ "$(wc -l < .repo/project.list)" -gt 500 ]]; then
  log "large checkout already present, re-syncing"
fi

repo sync -c -j"$SYNC_THREADS" --force-sync --no-clone-bundle --no-tags

log "sync complete"

# ---------------------------------------------------------------- 4. patches

step "4/5 apply device tree patches"

if [[ ! -d "device/bluefox/$DEVICE" ]]; then
  die "device/bluefox/$DEVICE missing after sync - check local_manifests/nx1.xml"
fi

# Run the patch script against this checkout. It lives in the project
# directory, so point it at the source root explicitly.
chmod +x "$SCRIPT_DIR/apply-patches.sh"
SRC_ROOT="$SRC_DIR" "$SCRIPT_DIR/apply-patches.sh"

# ---------------------------------------------------------------- 5. build

step "5/5 build"

export USE_CCACHE=1
export CCACHE_EXEC="$(command -v ccache || echo /usr/bin/ccache)"
ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 || warn "ccache not configured"
ccache -o compression=true >/dev/null 2>&1 || true
log "ccache: $CCACHE_SIZE, compression on"

# shellcheck disable=SC1091
source build/envsetup.sh

log "breakfast $DEVICE"
breakfast "$DEVICE"

log "brunch $DEVICE -j$JOBS"
brunch "$DEVICE" -j"$JOBS"

# ---------------------------------------------------------------- summary

step "done"

OUT_DIR="out/target/product/$DEVICE"
if [[ -d "$OUT_DIR" ]]; then
  log "artifacts in $OUT_DIR:"
  ls -lh "$OUT_DIR"/*.zip "$OUT_DIR"/recovery.img "$OUT_DIR"/boot.img 2>/dev/null || true
  echo
  log "flash with: scripts/flash.sh"
else
  warn "no output directory at $OUT_DIR"
fi
