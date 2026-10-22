#!/usr/bin/env bash
# scripts/03-build-lfs-system.sh
#
# Stage 03 — build the rest of the LFS system inside the chroot (chapter 8).
#
# From here on, all builds run *inside* `chroot $LFS` as root, using
# /tools/bin/* as the bootstrap compiler and /usr/bin as the target
# install prefix. We build the remaining ~250 packages that constitute
# a base LFS system:
#
#   - userspace libs: gmp, mpfr, mpc, zlib, xz, zstd, bzip2, readline,
#                     elfutils, attr, acl, libcap, openssl, libffi, pcre2
#   - base utils:     gawk, findutils, grep, sed, pkg-config, libtool,
#                     gdbm, gperf, expat, inetutils, less, perl, xml::parser
#   - networking:     iproute2, iputils, wget, curl, openssh
#   - system:         procps, psmisc, util-linux, kbd, kmod, man-pages,
#                     shadow (users), sudo, libpipeline, zlib
#   - toolchain (final, native, on the real rootfs):
#       binutils pass-3, gcc pass-3 (rebuilt against /usr libs)
#   - init:           systemd 256.x
#   - shell:          bash final, dash
#   - bootloaders:     grub, efibootmgr, os-prober
#   - data:            iana-etc, tzdata, ca-certificates
#
# Result: $LFS is a fully bootable native userspace. The kernel and
# bootloader are configured in stages 05 and 06.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="03-lfs-system"
orion_banner

# A package list with: <pkg-name>:<build-script-path>
# Build scripts are sourced inside chroot $LFS, working dir = /sources/<pkg>-build
LFS_PKGS=(
  "iana-etc:       iana-etc/build"
  "tzdata:         tzdata/build"
  "zlib:           zlib/build"
  "bzip2:          bzip2/build"
  "xz:             xz/build variant=native"
  "zstd:           zstd/build variant=native"
  "file-final:     file/build variant=native"
  "readline:       readline/build"
  "m4-final:       m4/build variant=native"
  "bc-final:       bc/build variant=native"
  "gmp-final:      gmp/build variant=native"
  "mpfr-final:     mpfr/build variant=native"
  "mpc-final:      mpc/build variant=native"
  "attr:           attr/build"
  "acl:            acl/build"
  "libcap:         libcap/build"
  "libelf:         elfutils/build target=libelf"
  "libffi:         libffi/build"
  "openssl:        openssl/build"
  "pcre2:          pcre2/build"
  "ncurses-final:  ncurses/build variant=native"
  "bash-final:     bash/build variant=final"
  "coreutils-final: coreutils/build variant=final"
  "diffutils-final: diffutils/build variant=native"
  "expat:          expat/build"
  "elfutils-final: elfutils/build target=elfutils"
  "findutils-final: findutils/build variant=native"
  "gawk-final:     gawk/build variant=native"
  "grep-final:     grep/build variant=native"
  "gzip-final:     gzip/build variant=native"
  "make-final:     make/build variant=final"
  "patch-final:    patch/build variant=native"
  "sed-final:      sed/build variant=native"
  "tar-final:      tar/build variant=final"
  "texinfo:        texinfo/build"
  "gperf:          gperf/build"
  "markupsafe:     markupsafe/build"
  "jinja2:         jinja2/build"
  "python3:        python/build"
  "wheel:          python/build target=wheel"
  "setuptools:     python/build target=setuptools"
  "flit-core:      python/build target=flit"
  "psmisc:         psmisc/build"
  "procps:         procps/build"
  "util-linux-final: util-linux/build variant=final"
  "kbd:            kbd/build"
  "kmod:           kmod/build"
  "libpipeline:    libpipeline/build"
  "shadow:         shadow/build"
  "sudo:           sudo/build"
  "bison:          bison/build"
  "flex:           flex/build"
  "pkg-config:      pkgconfig/build"
  "libtool:        libtool/build"
  "gdbm:           gdbm/build"
  "gdb:            gdb/build"
  "icu:            icu/build"
  "perl:           perl/build"
  "xml-parser:     xmlparser/build"
  "intltool:       intltool/build"
  "autoconf:       autoconf/build"
  "automake:       automake/build"
  "xz-utils:       xz/build target=utils"
  "kmod-final:     kmod/build variant=final"
  "less:           less/build"
  "iproute2:       iproute2/build"
  "iputils:        iputils/build"
  "inetutils:      inetutils/build"
  "wget:           wget/build"
  "curl:           curl/build"
  "openssh:        openssh/build"
  "ca-certificates: ca-certs/build"
  "pcre2-final:    pcre2/build variant=final"
  "json-c:         json-c/build"
  "cryptsetup:     cryptsetup/build"
  "dbus:           dbus/build"
  "dbus-broker:    dbus-broker/build"
  "glib2:          glib2/build"
  "systemd:        systemd/build"
  "polkit:         polkit/build"
  "shadow-final:   shadow/build variant=final"
  "iana-final:     iana-etc/build variant=final"
)

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------
chroot_build() {
  local pkg="$1"; local script="$2"; shift 2
  orion_log "chroot build: $pkg $*"
  # Copy the package script into $LFS so it's reachable inside the chroot
  mkdir -p "$LFS/usr/src/orion/packages"
  cp -r "$(dirname "$script")" "$LFS/usr/src/orion/packages/" 2>/dev/null || true

  orion_chroot "
    set -e
    cd /sources
    rm -rf $pkg-build
    mkdir  $pkg-build
    cd     $pkg-build
    source /usr/src/orion/packages/$(basename "$script") $*
  "
}

for entry in "${LFS_PKGS[@]}"; do
  pkg="${entry%%:*}"
  pkg="${pkg// /}"
  script="${entry#*:}"
  script="${script// /}"
  orion_run_stage "lfs-$pkg" "build $pkg" -- bash -c "chroot_build $pkg $script"
done

# Final cleaning — strip binaries, clean /tools, delete build trees
orion_run_stage "cleanup" "strip + clean LFS (LFS §8.x)" -- bash -c '
  orion_chroot "
    set -e
    # Strip debug info from binaries
    find /usr/{lib,libexec,bin,sbin} -type f -executable ! -name "*.so*" \
      -exec /tools/bin/strip --strip-debug {} + 2>/dev/null || true
    # Remove build trees
    rm -rf /sources/*-build /sources/*-build-*
    # Keep sources so packages can be re-built later, but compress them
    cd /sources
    find . -maxdepth 1 -name "*.tar.*" -exec xz -T0 -9 {} + 2>/dev/null || true
    # /tools is still needed by orion-pkg for bootstrapping new packages
    # — keep it. Will be cleaned at image time if needed.
  "
'

orion_log "stage 03 complete — $LFS is a full base userspace"
# vim: set ts=2 sw=2 noet:
