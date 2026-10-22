#!/usr/bin/env bash
# scripts/02-build-temp-tools.sh
#
# Stage 02 — build the temporary chroot tools (LFS chapter 6 & 7).
#
# This builds the *native* (running on the target arch, producing target
# binaries) versions of the toolchain plus enough utilities to bootstrap
# the rest of the system inside a chroot:
#
#   - m4, ncurses, bash, coreutils, diffutils, file, findutils, gawk,
#     grep, gzip, make, patch, sed, tar, xz, zstd
#   - binutils & gcc (native, pass 3, this time inside $LFS)
#
# After this stage we can `chroot $LFS` and have a self-contained
# build environment with no further dependency on the host's /usr.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="02-temp-tools"
orion_banner

# Switch from cross-toolchain triplet to "native":
# Inside the chroot, the prefix is /usr and the triplet is $LFS_TGT,
# but for stage-02 toolchain rebuilds we set CC=$LFS_TGT-gcc etc.

run_as_orionlfs() {
  sudo -u "$ORION_LFS_USER" \
    env -i HOME=/home/"$ORION_LFS_USER" \
        TERM="$TERM" \
        PATH=/tools/bin:/usr/bin:/bin \
        LFS="$LFS" LFS_TGT="$LFS_TGT" \
        MAKEFLAGS="$MAKEFLAGS" \
        /bin/bash -c "set -euo pipefail; $1"
}

build_pkg() {
  local pkg="$1"; local build_script="$2"; shift 2
  orion_log "building $pkg $*"
  run_as_orionlfs "
    cd \$LFS/sources
    rm -rf $pkg-build
    mkdir  $pkg-build
    cd     $pkg-build
    source /usr/src/orion/packages/$build_script $*
  "
}

# --- 1. Change ownership of $LFS to root -------------------------------------
orion_run_stage "claim-lfs" "chown -R root:root $LFS (LFS §7.3)" -- bash -c '
  chown -R root:root '"$LFS"'/{usr,lib,lib64,var,etc,bin,sbin,tools}
  chmod -R 0755 '"$LFS"'/{usr,lib,lib64,var,etc,bin,sbin,tools}
  chown -R root:root '"$LFS"'/sources '"$LFS"'/build 2>/dev/null || true
'

# --- 2. Prepare for chroot: symlink $LFS/tools -> /tools ----------------------
orion_run_stage "tools-link" "ensure /tools symlinked" -- bash -c '
  ln -sfn '"$LFS"'/tools /tools
'

# --- 3. The temp-tool chain (each entry runs its own build_pkg) ---------------
TEMP_PKGS=(
  "m4:            m4/build"
  "ncurses:       ncurses/build"
  "bash-temp:     bash/build variant=temp"
  "bc:            bc/build"
  "coreutils-temp: coreutils/build variant=temp"
  "diffutils:     diffutils/build"
  "file:          file/build"
  "findutils:     findutils/build"
  "gawk:          gawk/build"
  "grep:          grep/build"
  "gzip:          gzip/build"
  "make-temp:     make/build variant=temp"
  "patch:         patch/build"
  "sed:           sed/build"
  "tar-temp:      tar/build variant=temp"
  "xz:            xz/build"
  "zstd:          zstd/build"
)

for entry in "${TEMP_PKGS[@]}"; do
  pkg="${entry%%:*}"
  pkg="${pkg// /}"
  script="${entry#*:}"
  script="${script// /}"
  orion_run_stage "temp-$pkg" "build $pkg" -- bash -c "build_pkg $pkg $script"
done

# --- 4. Rebuild binutils & gcc natively (pass 3 / chapter 6) -----------------
orion_run_stage "binutils-pass3" "build binutils native (chroot)" -- \
  bash -c 'build_pkg binutils-pass3 binutils/build pass=3'

orion_run_stage "gcc-pass3" "build gcc native (chroot)" -- \
  bash -c 'build_pkg gcc-pass3 gcc/build pass=3'

# --- 5. Rebuild bash & coreutils as native (LFS chapter 7) -------------------
orion_run_stage "bash-native" "rebuild bash as a real /usr/bin/bash" -- \
  bash -c 'build_pkg bash-native bash/build variant=native'

orion_run_stage "coreutils-native" "rebuild coreutils for /usr" -- \
  bash -c 'build_pkg coreutils-native coreutils/build variant=native'

# --- 6. Sanity check the temp toolchain --------------------------------------
orion_run_stage "smoke" "toolchain sanity smoke" -- bash -c '
  "$LFS"/tools/bin/'"$LFS_TGT"'-gcc -dumpmachine | grep -q "'"$ORION_ARCH"'" \
    || orion_die "toolchain no longer reports the right arch"
  test -x "$LFS"/tools/bin/bash || orion_die "missing /tools/bin/bash"
  test -x "$LFS"/tools/bin/make || orion_die "missing /tools/bin/make"
'

orion_log "stage 02 complete — $LFS is now chrootable"
# vim: set ts=2 sw=2 noet:
