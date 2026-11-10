#!/usr/bin/env bash
#
# setup-host.sh - prepare a fresh Ubuntu 22.04/24.04 x86_64 host for
#                 LineageOS 24.0 builds
#
# Verified against LineageOS wiki requirements for lineage-24.0:
#   64 GB RAM, 400 GB disk, Ubuntu 20.04 LTS or newer, x86_64
#
# Usage:
#   curl -fsSL <raw-url>/scripts/setup-host.sh | sudo bash
#   # or
#   sudo ./scripts/setup-host.sh
#
set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

# ---------------------------------------------------------------- checks

log "host: $(uname -srm)"

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux only"
[[ "$(uname -m)" == "x86_64" ]] || die "AOSP prebuilt toolchains require x86_64, got $(uname -m)"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  log "distro: ${PRETTY_NAME:-unknown}"
fi

mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
log "RAM: ${mem_gb} GB"
[[ "$mem_gb" -ge 32 ]] || warn "lineage-24.0 officially wants 64 GB; ${mem_gb} GB will be slow"

disk_gb=$(df -Pk / | awk 'NR==2{printf "%d", $4/1048576}')
log "free disk on /: ${disk_gb} GB"
[[ "$disk_gb" -ge 400 ]] || warn "400 GB recommended; ${disk_gb} GB may run out"

# ---------------------------------------------------------------- packages

log "installing build packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

PKGS=(
  bc bison build-essential ccache curl erofs-utils flex
  g++-multilib gcc-multilib git git-lfs gnupg gperf
  imagemagick kmod protobuf-compiler python3-protobuf
  lib32readline-dev lib32z1-dev libdw-dev libelf-dev
  libgnutls28-dev lz4 libsdl1.2-dev libssl-dev
  libxml2 libxml2-utils lzop pngcrush rsync schedtool
  squashfs-tools xsltproc xxd zip zlib1g-dev
  python-is-python3 openjdk-21-jdk
  android-sdk-libsparse-utils
  rsync aria2
)

# Ubuntu 26.04+ renamed libxml2
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${VERSION_ID:-0}" == 26.* ]]; then
    PKGS=("${PKGS[@]/libxml2/libxml2-16}")
  fi
fi

apt-get install -y --no-install-recommends "${PKGS[@]}"

# ---------------------------------------------------------------- repo

log "installing repo"
install -d -m 755 /usr/local/bin
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
chmod a+x /usr/local/bin/repo

# ---------------------------------------------------------------- ccache

log "configuring ccache for the build user"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]]; then
  BASHRC="$TARGET_HOME/.bashrc"
  if ! grep -q 'USE_CCACHE' "$BASHRC" 2>/dev/null; then
    {
      echo ''
      echo '# --- LineageOS build environment ---'
      echo 'export USE_CCACHE=1'
      echo 'export CCACHE_EXEC=/usr/bin/ccache'
      echo 'export CCACHE_DIR=$HOME/.ccache'
      echo 'export LC_ALL=C'
      echo 'export PATH=$HOME/bin:$PATH'
    } >> "$BASHRC"
    chown "$TARGET_USER":"$TARGET_USER" "$BASHRC" 2>/dev/null || true
    log "appended build env to $BASHRC"
  else
    log "build env already present in $BASHRC"
  fi

  sudo -u "$TARGET_USER" ccache -M 100G >/dev/null
  sudo -u "$TARGET_USER" ccache -o compression=true >/dev/null
  log "ccache set to 100G with compression"
fi

# ---------------------------------------------------------------- swap

if [[ "$mem_gb" -lt 64 ]]; then
  SWAPFILE=/swapfile
  if [[ ! -f "$SWAPFILE" ]]; then
    log "adding 32 GB swap (RAM is ${mem_gb} GB, below the 64 GB target)"
    fallocate -l 32G "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon "$SWAPFILE"
    grep -q "$SWAPFILE" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    log "swap enabled"
  else
    log "swapfile already present"
  fi
fi

# ---------------------------------------------------------------- git

if [[ -n "$TARGET_HOME" ]]; then
  sudo -u "$TARGET_USER" git config --global trailer.changeid.key "Change-Id" || true
  sudo -u "$TARGET_USER" git lfs install --skip-repo 2>/dev/null || warn "git lfs install failed"
fi

# ---------------------------------------------------------------- summary

cat <<EOF

$GRN=== host ready ===$RST

RAM    : ${mem_gb} GB
Disk   : ${disk_gb} GB free
Cores  : $(nproc)
Swap   : $(free -g | awk '/Swap/{print $2}') GB

Next, as ${TARGET_USER}:

  # 1. get this project
  git clone <your-fork-url> ~/nx1-lineage24
  cd ~/nx1-lineage24

  # 2. full build (sync + patch + compile)
  ./build.sh

  # or stage by stage:
  SRC_DIR=~/android/lineage ./build.sh     # uses this dir for sources

Build takes 4-8 h cold. Rebuilds with warm ccache: 20-40 min.

EOF
