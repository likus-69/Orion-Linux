#!/usr/bin/env bash
# scripts/01-build-cross-toolchain.sh
#
# Stage 01 — build the cross-toolchain (LFS chapter 5).
#
# This builds the temporary tools that run on the host but produce binaries
# for the $LFS_TGT triplet:
#
#   - binutils pass 1    (assembler, linker for $LFS_TGT)
#   - gcc pass 1         (C compiler for $LFS_TGT, no libc yet)
#   - glibc              (target C library, installed into $LFS)
#   - libstdc++          (from gcc, target)
#   - binutils pass 2    (re-linked against the new glibc)
#   - gcc pass 2         (full compiler: C, C++, Fortran)
#
# Plus the math prereqs: gmp, mpfr, mpc. (isl is skipped — gcc 14 has
# it built-in for our default config.)
#
# All sources live under $LFS/sources. All build trees under /sources/build.
# Result: a /tools/bin/${LFS_TGT}-* toolchain that produces target binaries.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="01-cross-toolchain"
orion_banner

run_as_orionlfs() {
  sudo -u "$ORION_LFS_USER" \
    env -i HOME=/home/"$ORION_LFS_USER" \
        TERM="$TERM" \
        PATH=/usr/bin:/bin \
        LFS="$LFS" LFS_TGT="$LFS_TGT" \
        MAKEFLAGS="$MAKEFLAGS" \
        /bin/bash -c "set -euo pipefail; $1"
}

# ---------------------------------------------------------------------------
# Helper: build one LFS package inside its own build dir.
# Args: <pkg-dir-name> <build-script-relative-to-packages/>
# ---------------------------------------------------------------------------
build_pkg() {
  local pkg="$1"; local build_script="$2"
  orion_log "building $pkg"
  run_as_orionlfs "
    cd \$LFS/sources
    rm -rf $pkg-build
    mkdir  $pkg-build
    cd     $pkg-build
    # Source the build script (which calls configure/make/install)
    source /usr/src/orion/packages/$build_script
  "
}

# --- 1. Fetch sources --------------------------------------------------------
orion_run_stage "fetch-sources" "download all stage-01 sources" -- bash -c '
  mkdir -p '"$ORION_SOURCES"'
  cd '"$ORION_SOURCES"'
  for url in \
    https://ftp.gnu.org/gnu/binutils/binutils-2.43.tar.xz \
    https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz \
    https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz \
    https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz \
    https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz \
    https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz \
    https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.12.4.tar.xz ; do
    orion_fetch "$url"
  done
'

# --- 2. Extract & lay out gcc source tree (gmp/mpfr/mpc inside gcc/) ----------
orion_run_stage "prep-gcc-tree" "place math libs inside gcc source tree" -- bash -c '
  cd '"$ORION_SOURCES"'
  [[ -d gcc-'"${LFS_VERSIONS[gcc]}"' ]] || tar xf gcc-'"${LFS_VERSIONS[gcc]}"'.tar.xz
  cd gcc-'"${LFS_VERSIONS[gcc]}"'
  [[ -e gmp ]] && rm -f gmp; ln -s ../gmp-'"${LFS_VERSIONS[gmp]}"' gmp
  [[ -e mpfr ]] && rm -f mpfr; ln -s ../mpfr-'"${LFS_VERSIONS[mpfr]}"' mpfr
  [[ -e mpc ]] && rm -f mpc; ln -s ../mpc-'"${LFS_VERSIONS[mpc]}"' mpc
  chown -R '"$ORION_LFS_USER"':'"$(id -gn "$ORION_LFS_USER")"' '"$ORION_SOURCES"'
'

# --- 3. binutils pass 1 ------------------------------------------------------
orion_run_stage "binutils-pass1" "build binutils pass 1 (target $LFS_TGT)" -- \
  bash -c 'build_pkg binutils-pass1 binutils/build pass=1'

# --- 4. gcc pass 1 (C-only, against headers-only libc) -----------------------
orion_run_stage "gcc-pass1" "build gcc pass 1 (C only, no libc yet)" -- \
  bash -c 'build_pkg gcc-pass1 gcc/build pass=1'

# --- 5. Linux API headers (target libc headers) ------------------------------
orion_run_stage "linux-headers" "install linux 6.12.4 API headers" -- \
  bash -c 'build_pkg linux-headers linux/build target=headers'

# --- 6. glibc (target C library) ---------------------------------------------
orion_run_stage "glibc" "build glibc ${LFS_VERSIONS[glibc]} for $ORION_ARCH" -- \
  bash -c 'build_pkg glibc glibc/build'

# --- 7. libstdc++ (from gcc, target, against the new glibc) ------------------
orion_run_stage "libstdc++" "build libstdc++ from gcc pass 1" -- \
  bash -c 'build_pkg libstdc++-pass1 gcc/build target=libstdcxx'

# --- 8. binutils pass 2 ------------------------------------------------------
orion_run_stage "binutils-pass2" "build binutils pass 2 (linked against new libc)" -- \
  bash -c 'build_pkg binutils-pass2 binutils/build pass=2'

# --- 9. gcc pass 2 (full compiler) ------------------------------------------
orion_run_stage "gcc-pass2" "build gcc pass 2 (C/C++/Fortran)" -- \
  bash -c 'build_pkg gcc-pass2 gcc/build pass=2'

# --- 10. Smoketest -----------------------------------------------------------
orion_run_stage "smoke" "compile hello.c with the new toolchain" -- bash -c '
  cat > /tmp/hello.c <<EOF
#include <stdio.h>
int main(void){ puts("hello from orion cross-toolchain"); return 0; }
EOF
  '"$LFS"'/tools/bin/'"$LFS_TGT"'-gcc -o /tmp/hello /tmp/hello.c
  file /tmp/hello
  /tmp/hello || file /tmp/hello | grep -q "ELF .* '"$ORION_ARCH"'" \
    || orion_die "smoke test failed: wrong arch output"
'

orion_log "stage 01 complete — /tools/bin/${LFS_TGT}-* ready"
# vim: set ts=2 sw=2 noet:
