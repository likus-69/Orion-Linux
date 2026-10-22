#!/usr/bin/env bash
# scripts/lib/common.sh
#
# Shared helpers for the Orion Linux build pipeline.
# Sourced by every scripts/NN-*.sh stage file.

# Make sure we're sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: common.sh is a library — do not execute directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Global config (override via environment)
# ---------------------------------------------------------------------------
: "${ORION_ARCH:=$(uname -m)}"
: "${ORION_VERSION:=$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
: "${ORION_BUILD_ROOT:=$PWD/build}"
: "${ORION_SOURCES:=$ORION_BUILD_ROOT/sources}"
: "${ORION_LOG_DIR:=$ORION_BUILD_ROOT/logs}"
: "${ORION_LFS_USER:=orionlfs}"
: "${ORION_JOBS:=$(nproc 2>/dev/null || echo 2)}"
: "${LFS:=/mnt/orion}"          # mount point of the future system
: "${LFS_TGT:=$ORION_ARCH-orion-linux-gnu}"
: "${MAKEFLAGS:=-j$ORION_JOBS}"
: "${ORION_MIRROR:=https://sources.buildroot.net}"

# LFS 12.3 reference book versions (frozen for reproducibility)
declare -A LFS_VERSIONS=(
  [binutils]=2.43
  [gcc]=14.2.0
  [glibc]=2.40
  [linux]=6.12.4
  [gmp]=6.3.0
  [mpfr]=4.2.1
  [mpc]=1.3.1
  [bash]=5.2.32
  [coreutils]=9.5
  [systemd]=256.8
  [grub]=2.12
  [openssl]=3.4.0
  [util-linux]=2.40.2
  [iana-etc]=20241125
  [tzdata]=2024b
  [zstd]=1.5.6
  [xz]=5.6.3
  [zlib]=1.3.1
)

export ORION_ARCH ORION_VERSION ORION_BUILD_ROOT ORION_SOURCES ORION_LOG_DIR
export ORION_LFS_USER ORION_JOBS LFS LFS_TGT MAKEFLAGS LFS_VERSIONS

# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  C_BOLD=""; C_DIM=""
fi

orion_log()   { echo "${C_BLUE}==>${C_RESET} $*"; }
orion_info()  { echo "${C_DIM}    $*${C_RESET}"; }
orion_ok()    { echo "${C_GREEN}    OK: $*${C_RESET}"; }
orion_warn()  { echo "${C_YELLOW}!!  $*${C_RESET}" >&2; }
orion_err()   { echo "${C_RED}XX  $*${C_RESET}" >&2; }
orion_stage() { echo ""; echo "${C_BOLD}${C_BLUE}===>> [stage] $*${C_RESET}"; }

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
orion_current_stage="startup"

orion_die() {
  orion_err "stage '$orion_current_stage' failed at line ${BASH_LINENO[0]}"
  orion_err "message: $*"
  orion_err "see log: $ORION_LOG_DIR/$orion_current_stage.log"
  exit 1
}

# Trap any error in any sourced script and route through orion_die
trap 'orion_die "uncaught error (exit $?)"' ERR

# Run a stage: orion_run_stage "stage-name" "description" -- <command...>
orion_run_stage() {
  local name="$1"; shift
  local desc="$1"; shift
  [[ "$1" == "--" ]] || orion_die "orion_run_stage: missing '--' separator"
  shift
  orion_current_stage="$name"
  orion_stage "$desc ($name)"
  mkdir -p "$ORION_LOG_DIR"
  local log="$ORION_LOG_DIR/$name.log"
  : > "$log"
  orion_info "logging to $log"
  orion_info "running: $*"
  if "$@" 2>&1 | tee -a "$log"; then
    orion_ok "stage $name complete"
    return 0
  else
    orion_die "stage $name returned non-zero"
  fi
}

# ---------------------------------------------------------------------------
# Source / checksum helpers
# ---------------------------------------------------------------------------
# Verify a downloaded file against an expected sha256.
orion_verify_sha256() {
  local file="$1"; local expected="$2"
  [[ -f "$file" ]] || orion_die "missing file: $file"
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [[ "$actual" == "$expected" ]]; then
    orion_ok "sha256 verified: $(basename "$file")"
    return 0
  fi
  orion_die "sha256 mismatch for $(basename "$file"):
  expected: $expected
  actual:   $actual"
}

# Download a source URL to the sources dir, with mirror fallback.
orion_fetch() {
  local url="$1"; local dest="${2:-$ORION_SOURCES/$(basename "$url")}"
  mkdir -p "$ORION_SOURCES"
  if [[ -f "$dest" ]] && (( $(stat -c%s "$dest") > 0 )); then
    orion_info "cache hit: $dest"
    return 0
  fi
  orion_log "fetch: $url"
  if ! curl -fL --retry 3 --connect-timeout 30 -o "$dest.partial" "$url"; then
    rm -f "$dest.partial"
    # Try our mirror
    local mirror_url="$ORION_MIRROR/$(basename "$url")"
    orion_warn "primary fetch failed, trying mirror: $mirror_url"
    curl -fL --retry 3 -o "$dest.partial" "$mirror_url" || orion_die "fetch failed"
  fi
  mv "$dest.partial" "$dest"
}

# ---------------------------------------------------------------------------
# Environment / host checks
# ---------------------------------------------------------------------------
orion_check_host() {
  orion_log "checking host prerequisites"
  for tool in bash gcc g++ make curl tar xz bison flex perl python3; do
    command -v "$tool" >/dev/null 2>&1 || orion_die "missing host tool: $tool"
  done
  # LFS 12.3 minimum version requirements
  local v
  v=$(bash --version | head -1 | awk '{print $4}')
  awk "BEGIN {exit !($v >= 4.4)}" || orion_die "bash >= 4.4 required (have $v)"
  v=$(gcc -dumpversion | cut -d. -f1)
  awk "BEGIN {exit !($v >= 12)}" || orion_die "gcc >= 12 required (have $v)"
  orion_ok "host OK ($(uname -srm), $(nproc) cores)"
}

# ---------------------------------------------------------------------------
# chroot / mount helpers
# ---------------------------------------------------------------------------
orion_mount_vfs() {
  orion_log "mounting virtual filesystems under $LFS"
  mkdir -p "$LFS"
  mountpoint -q "$LFS/dev"   || mount --bind /dev   "$LFS/dev"
  mountpoint -q "$LFS/proc"  || mount -t proc        "$LFS/proc"
  mountpoint -q "$LFS/sys"  || mount --rbind /sys    "$LFS/sys"
  mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs  "$LFS/run"
  if [[ -d /dev/shm ]]; then
    mountpoint -q "$LFS/dev/shm" || mount --bind /dev/shm "$LFS/dev/shm"
  fi
}

orion_unmount_vfs() {
  orion_log "unmounting virtual filesystems under $LFS"
  for sub in dev/shm dev/pts dev run sys proc dev; do
    if mountpoint -q "$LFS/$sub"; then
      umount -R "$LFS/$sub" 2>/dev/null || true
    fi
  done
}

# Enter chroot with a clean environment. Pass the command to run as $@.
orion_chroot() {
  [[ $# -gt 0 ]] || orion_die "orion_chroot: no command given"
  orion_mount_vfs
  orion_info "entering chroot: $*"
  chroot --userspec=0:0 "$LFS" \
    /usr/bin/env -i \
      HOME=/root \
      TERM="$TERM" \
      PS1='orion-chroot \w # ' \
      PATH=/usr/bin:/usr/sbin:/bin:/sbin \
      /bin/bash -c "set -euo pipefail; $*"
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
orion_on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    orion_warn "build interrupted (exit $rc) — virtual filesystems may still be mounted"
    orion_warn "to clean up: sudo umount -R $LFS"
  fi
  return $rc
}
trap orion_on_exit EXIT

# Print a banner so log files are easy to grep across stages
orion_banner() {
  cat <<EOF

============================================================
  Orion Linux build
  arch:    $ORION_ARCH
  version: $ORION_VERSION
  jobs:    $ORION_JOBS
  root:    $LFS
  time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
============================================================

EOF
}

# vim: set ts=2 sw=2 noet:
