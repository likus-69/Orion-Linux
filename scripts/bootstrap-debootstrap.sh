#!/usr/bin/env bash
# scripts/bootstrap-debootstrap.sh
#
# v0.1 fast-path: build a minimal Orion Linux rootfs using Debian's
# debootstrap as a base, then layer our branding, kernel, orion-pkg,
# and installer on top.
#
# This replaces stages 00-03 of the LFS pipeline for v0.1. The full LFS
# build (stages 00-03) is still in scripts/0[0-3]-*.sh and will become
# the v0.2 path once enough LFS package definitions land in packages/.
#
# Output: a rootfs at $LFS (default /mnt/orion) containing:
#   - Debian 12 (bookworm) minimal base
#   - linux kernel 7.3 (compiled from the user's fork of torvalds/linux)
#   - grub-efi + grub-pc binaries
#   - orion-pkg + orion-installer installed at /usr/bin
#   - /etc/os-release, motd, hostname, etc. (Orion branding)
#   - systemd enabled, root account locked, default user "orion"
#   - dracut initramfs generator installed (for the live ISO)

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="bootstrap-debootstrap"
orion_banner

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
: "${ORION_DEB_MIRROR:=https://deb.debian.org/debian}"
: "${ORION_DEB_SUITE:=bookworm}"
: "${ORION_DEB_VARIANT:=minbase}"   # minbase = smallest, no man pages, no apt
: "${ORION_ARCH:=$(uname -m)}"
: "${ORION_INCLUDE_PKGS:=systemd,systemd-sysv,udev,dbus,iproute2,iputils-ping,openssh-server,openssh-client,ca-certificates,curl,less,vim,passwd,adduser,sudo,bash-completion,locales,kmod,procps,util-linux,dracut,xz-utils,zstd,tar,gzip,bzip2,coreutils,findutils,grep,sed,gawk}"

# Map uname -m to Debian arch name
case "$ORION_ARCH" in
  x86_64)  DEB_ARCH=amd64 ;;
  aarch64) DEB_ARCH=arm64 ;;
  *) orion_die "unsupported arch for debootstrap: $ORION_ARCH" ;;
esac

orion_log "Phase 1: debootstrap $ORION_DEB_SUITE / $DEB_ARCH variant=$ORION_DEB_VARIANT"

# Detect foreign arch (e.g. building aarch64 on x86_64 host)
HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "$DEB_ARCH")
if [[ "$DEB_ARCH" != "$HOST_ARCH" ]]; then
  ORION_DEB_FOREIGN="--foreign"
  orion_log "foreign arch detected (host=$HOST_ARCH target=$DEB_ARCH) — using debootstrap --foreign + qemu binfmt"
else
  ORION_DEB_FOREIGN=""
fi

# -----------------------------------------------------------------------------
# Stage bodies as functions (so they have access to common.sh helpers like
# orion_log, orion_warn, etc. — bash -c '...' blocks do NOT inherit funcs.)
# -----------------------------------------------------------------------------

stage_host_prep() {
  set -euo pipefail
  if ! command -v debootstrap >/dev/null 2>&1; then
    orion_warn "debootstrap not found — installing via apt"
    [[ $EUID -eq 0 ]] || orion_die "must run as root for apt install"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      debootstrap debian-archive-keyring squashfs-tools xorriso mtools dosfstools
  fi
  # For foreign-arch builds we need qemu-user-static
  if [[ -n "$ORION_DEB_FOREIGN" ]]; then
    orion_log "foreign arch — checking qemu-user-static"
    if ! command -v "qemu-${DEB_ARCH}-static" >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends qemu-user-static \
        || orion_die "qemu-user-static needed for foreign-arch build"
    fi
    # Register binfmt handlers if not already registered
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-${DEB_ARCH} ]]; then
      mountpoint -q /proc/sys/fs/binfmt_misc || \
        mount -t binfmt_misc binfmt /proc/sys/fs/binfmt_misc
      update-binfmts --enable "qemu-${DEB_ARCH}" 2>/dev/null || true
    fi
  fi
  orion_ok "host ready"
}

stage_debootstrap() {
  set -euo pipefail
  mkdir -p "$LFS"
  # If $LFS already populated, skip
  if [[ -d "$LFS/usr/bin" && -x "$LFS/usr/bin/bash" ]]; then
    orion_info "$LFS already populated — skipping debootstrap (rm -rf $LFS/* to force)"
    return 0
  fi
  orion_log "running debootstrap (variant=$ORION_DEB_VARIANT arch=$DEB_ARCH include=$ORION_INCLUDE_PKGS)"
  debootstrap \
    --arch="$DEB_ARCH" \
    --variant="$ORION_DEB_VARIANT" \
    --include="$ORION_INCLUDE_PKGS" \
    ${ORION_DEB_FOREIGN} \
    "$ORION_DEB_SUITE" \
    "$LFS" \
    "$ORION_DEB_MIRROR"

  # If --foreign was used (cross-arch), complete the second stage inside the chroot
  if [[ -n "$ORION_DEB_FOREIGN" ]]; then
    orion_log "completing debootstrap second stage (foreign arch)"
    # Need /proc etc. mounted for the chroot to work
    orion_mount_vfs
    chroot "$LFS" /debootstrap/debootstrap --second-stage
    orion_unmount_vfs
  fi
  orion_ok "rootfs populated"
}

stage_apt_config() {
  set -euo pipefail
  cat > "$LFS/etc/apt/sources.list" <<EOF
# Minimal Orion Linux v0.1 apt sources (Debian 12 base).
# These will be progressively replaced by LFS-built packages in v0.2+.
deb $ORION_DEB_MIRROR $ORION_DEB_SUITE main contrib non-free
deb $ORION_DEB_MIRROR $ORION_DEB_SUITE-updates main contrib non-free
deb https://deb.debian.org/debian-security $ORION_DEB_SUITE-security main contrib non-free
EOF

  mkdir -p "$LFS/etc/apt/apt.conf.d"
  cat > "$LFS/etc/apt/apt.conf.d/10orion" <<'EOF'
// Orion Linux apt defaults
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Clean "true";
Acquire::Retries "3";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
}
EOF
  orion_ok "apt configured"
}

stage_branding() {
  set -euo pipefail
  install -Dm0644 config/os-release     "$LFS/etc/os-release"
  install -Dm0644 config/orion-release   "$LFS/etc/orion-release"
  install -Dm0644 config/issue           "$LFS/etc/issue"
  install -Dm0644 config/motd            "$LFS/etc/motd"
  install -Dm0644 config/hostname        "$LFS/etc/hostname"
  install -Dm0644 config/fstab.template  "$LFS/etc/fstab.template"
  install -Dm0644 config/branding/logo.txt "$LFS/usr/share/orion/logo.txt"
  # Issue.net for sshd banner
  cp "$LFS/etc/issue" "$LFS/etc/issue.net"
  orion_ok "branding applied"
}

stage_chroot_mount() {
  set -euo pipefail
  orion_mount_vfs
  # Copy resolv.conf so the chroot can resolve hostnames
  cp /etc/resolv.conf "$LFS/etc/resolv.conf"
  orion_ok "chroot mounted"
}

stage_install_orion_tools() {
  set -euo pipefail
  install -Dm0755 orion-pkg/orion-pkg                  "$LFS/usr/bin/orion-pkg"
  install -Dm0644 orion-pkg/completions/orion-pkg.bash "$LFS/usr/share/bash-completion/completions/orion-pkg"
  install -Dm0644 orion-pkg/README.md                  "$LFS/usr/share/doc/orion-pkg/README.md"
  install -Dm0755 installer/orion-installer            "$LFS/usr/bin/orion-installer"
  install -Dm0755 -d                                    "$LFS/usr/lib/orion-installer"
  install -Dm0755 installer/modules/*.sh                "$LFS/usr/lib/orion-installer/"
  install -Dm0644 installer/de-profiles/*.list         "$LFS/usr/share/orion/de-profiles/"
  mkdir -p "$LFS/var/orion/installed" "$LFS/var/orion/cache" "$LFS/var/orion/sources"
  # Copy the in-repo packages/ dir as the local repo
  mkdir -p "$LFS/etc/orion/repo.d"
  cp -r packages "$LFS/etc/orion/repo.d/local"
  # Seed the base manifest
  cat > "$LFS/var/orion/installed/base.meta" <<EOF
name=base
version=$ORION_VERSION
arch=$ORION_ARCH
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
files=/etc/orion-release
EOF
  orion_ok "orion tools installed"
}

stage_config_system() {
  set -euo pipefail
  orion_chroot "
    set -e
    # Locales
    echo en_US.UTF-8 UTF-8 > /etc/locale.gen
    echo en_GB.UTF-8 UTF-8 >> /etc/locale.gen
    locale-gen
    echo LANG=en_US.UTF-8 > /etc/locale.conf
    echo KEYMAP=us > /etc/vconsole.conf
    # Timezone
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    # Lock root — installer sets the password
    passwd -l root >/dev/null 2>&1 || true
    # Create the default user
    if ! id -u orion >/dev/null 2>&1; then
      useradd -m -G users,systemd-journal,adm,sudo -s /bin/bash orion
      passwd -l orion >/dev/null 2>&1
    fi
    # Make sure sudo group exists and grants sudo
    getent group sudo >/dev/null 2>&1 || groupadd -r sudo
    echo '%sudo ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-sudo
    chmod 0440 /etc/sudoers.d/10-sudo
    # systemd default target
    ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl enable systemd-timesyncd 2>/dev/null || true
    systemctl enable ssh 2>/dev/null || true
  "
  orion_ok "system configured"
}

stage_fstab() {
  set -euo pipefail
  cat > "$LFS/etc/fstab" <<'EOF'
# Orion Linux fstab — overwritten by installer at install time.
# This minimal version lets the live ISO boot.
tmpfs          /tmp  tmpfs  mode=1777,nosuid,nodev        0 0
tmpfs          /run  tmpfs  mode=0755,nosuid,nodev,size=10% 0 0
proc           /proc proc   defaults                       0 0
sysfs          /sys  sysfs  defaults                       0 0
devtmpfs       /dev  devtmpfs defaults,mode=0755,size=4M   0 0
EOF
  orion_ok "fstab template written"
}

stage_manifest() {
  set -euo pipefail
  mkdir -p "$LFS/usr/share/orion"
  cat > "$LFS/usr/share/orion/rootfs.manifest" <<EOF
# Orion Linux rootfs manifest
name=Orion Linux
version=$ORION_VERSION
arch=$ORION_ARCH
bootstrap=debootstrap
bootstrap_suite=$ORION_DEB_SUITE
bootstrap_variant=$ORION_DEB_VARIANT
init=systemd
pkg_manager=orion-pkg (layered)
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host=$(hostname)
build_user=$USER
EOF
  orion_ok "manifest written"
}

stage_chroot_umount() {
  set -euo pipefail
  orion_unmount_vfs
  orion_ok "unmounted"
}

# --- Run stages ------------------------------------------------------------
orion_run_stage "host-prep"         "install host deps (debootstrap, arch helpers)" -- stage_host_prep
orion_run_stage "debootstrap"       "debootstrap $ORION_DEB_VARIANT into $LFS"     -- stage_debootstrap
orion_run_stage "apt-config"        "configure apt sources + apt.conf defaults"   -- stage_apt_config
orion_run_stage "branding"          "install /etc/os-release + motd + issue"        -- stage_branding
orion_run_stage "chroot-mount"      "bind /dev /proc /sys into $LFS"               -- stage_chroot_mount
orion_run_stage "install-orion-tools" "install orion-pkg + orion-installer"        -- stage_install_orion_tools
orion_run_stage "config-system"     "users, locale, tz, systemd defaults"          -- stage_config_system
orion_run_stage "fstab"             "write template fstab"                         -- stage_fstab
orion_run_stage "manifest"          "write rootfs.manifest"                        -- stage_manifest
orion_run_stage "chroot-umount"     "unmount virtual filesystems"                  -- stage_chroot_umount

orion_log "bootstrap complete — $LFS is a minimal Orion rootfs"
orion_log "next: scripts/05-build-kernel.sh + 06-build-bootloader.sh + 07-make-image.sh"
# vim: set ts=2 sw=2 noet:
