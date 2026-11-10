#!/usr/bin/env bash
#
# init-src.sh - initialise the LineageOS source checkout only
#
# Does step 1 and 2 of build.sh without syncing or building. Useful when
# you want to inspect the manifest before committing to a 200 GB download.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-24.0}"
SRC_DIR="${SRC_DIR:-$HOME/android/lineage}"

GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

if [[ -d .repo ]]; then
  log "existing checkout at $SRC_DIR"
else
  log "repo init -b $LINEAGE_BRANCH into $SRC_DIR"
  repo init -u https://github.com/LineageOS/android.git \
            -b "$LINEAGE_BRANCH" --git-lfs --no-clone-bundle
fi

mkdir -p .repo/local_manifests
cp "$SCRIPT_DIR/local_manifests/nx1.xml" .repo/local_manifests/nx1.xml
log "local manifest installed"

echo
log "manifest projects:"
grep -E '<project ' .repo/local_manifests/nx1.xml | sed 's/^[[:space:]]*/    /'

echo
warn "source not synced yet. next:"
echo "    cd $SRC_DIR && repo sync -c -j8 --force-sync --no-clone-bundle --no-tags"
echo
echo "  or run the whole pipeline:"
echo "    SRC_DIR=$SRC_DIR $SCRIPT_DIR/build.sh"
