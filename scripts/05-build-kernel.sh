#!/usr/bin/env bash
# scripts/05-build-kernel.sh
#
# Stage 05 — build the Linux kernel for $ORION_ARCH.
#
# Source: the user's fork of torvalds/linux at
#   https://github.com/likus-69/Orion-linux-v1.1
#
# Tag (default v7.3) is pinned in packages/linux/version.
#
# The kernel config lives in this repo (packages/linux/config-<arch>),
# NOT in the fork — fast iteration without pushing to the fork.
#
# Patches: drop any *.patch file into packages/linux/patches/ and the
# build will apply them with `patch -p1` before `make`. See
# packages/linux/patches/README.md for the format.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="05-kernel"
orion_banner

# Resolve version + tag from the package definition
KERNEL_VERSION="${LFS_VERSIONS[linux]}"
case "$KERNEL_VERSION" in
  6.12.4|6.12|6.18.*|7.*) : ;;   # known versions
  *) orion_warn "unexpected kernel version '$KERNEL_VERSION' — using anyway" ;;
esac
# Tag form: v<version>
KERNEL_TAG="v${KERNEL_VERSION}"

orion_log "kernel: ${KERNEL_VERSION} (tag ${KERNEL_TAG}) on ${ORION_ARCH}"

# --- 1. Clone the kernel source from the user's fork ------------------------
orion_run_stage "clone" "git clone --depth=1 --branch ${KERNEL_TAG} fork" -- bash -c '
  set -e
  # Clean any previous clone
  rm -rf '"$ORION_SOURCES"'/linux-'"$KERNEL_VERSION"'
  mkdir -p '"$ORION_SOURCES"'
  cd '"$ORION_SOURCES"'
  # Try the fork first; fall back to upstream torvalds/linux if the fork is
  # missing the tag (e.g. user has not synced the fork yet).
  if ! git clone --depth=1 --branch '"$KERNEL_TAG"' --no-tags --quiet \
        https://github.com/likus-69/Orion-linux-v1.1.git \
        linux-'"$KERNEL_VERSION"'; then
    orion_warn "fork does not have tag '"$KERNEL_TAG"' — falling back to torvalds/linux"
    orion_warn "  (run Sync Fork on https://github.com/likus-69/Orion-linux-v1.1"
    orion_warn "   to make this build use the fork)"
    git clone --depth=1 --branch '"$KERNEL_TAG"' --no-tags --quiet \
        https://github.com/torvalds/linux.git \
        linux-'"$KERNEL_VERSION"'
  fi
  # Drop .git to save space (~600 MB → ~1.2 GB on disk)
  rm -rf linux-'"$KERNEL_VERSION"'/.git
  chown -R root:root linux-'"$KERNEL_VERSION"'
  orion_ok "kernel source ready at '"$ORION_SOURCES"'/linux-'"$KERNEL_VERSION"'"
'

# --- 2. Apply patches from packages/linux/patches/ -------------------------
orion_run_stage "patches" "apply any *.patch files from packages/linux/patches/" -- bash -c '
  set -e
  patch_dir="/usr/src/orion/packages/linux/patches"
  if [[ ! -d "$patch_dir" || -z "$(ls -A "$patch_dir"/*.patch 2>/dev/null)" ]]; then
    echo "    no patches to apply"
    exit 0
  fi
  cd '"$ORION_SOURCES"'/linux-'"$KERNEL_VERSION"'
  for p in "$patch_dir"/*.patch; do
    echo "    applying $(basename "$p")"
    patch -p1 < "$p" || orion_die "patch failed: $(basename "$p")"
  done
  orion_ok "patches applied"
'

# --- 3. Pick the kernel config from this repo --------------------------------
orion_run_stage "defconfig" "install config from packages/linux/config-${ORION_ARCH}" -- bash -c '
  set -e
  case "'"$ORION_ARCH"'" in
    x86_64)  cfg=/usr/src/orion/packages/linux/config-x86_64 ;;
    aarch64) cfg=/usr/src/orion/packages/linux/config-aarch64 ;;
    *) orion_die "unsupported arch: '"$ORION_ARCH"'" ;;
  esac
  cp "$cfg" '"$ORION_SOURCES"'/linux-'"$KERNEL_VERSION"'/.config
  echo "    using $cfg"
'

# --- 4. Build inside chroot ------------------------------------------------
orion_run_stage "build" "make bzImage + modules" -- bash -c '
  orion_chroot "
    set -e
    cd /sources/linux-'"$KERNEL_VERSION"'
    # Oldconfig in case .config is from an older tree
    make olddefconfig
    # Sanity: make sure the essential CONFIGs for a desktop distro are on
    ./scripts/config \
      --enable CONFIG_BLK_DEV_INITRD \
      --enable CONFIG_SQUASHFS \
      --enable CONFIG_OVERLAY_FS \
      --enable CONFIG_EFIVAR_FS \
      --enable CONFIG_VIRTIO \
      --enable CONFIG_VIRTIO_PCI \
      --enable CONFIG_VIRTIO_BLK \
      --enable CONFIG_VIRTIO_NET \
      --enable CONFIG_DRM_VIRTIO_GPU \
      --enable CONFIG_DEVTMPFS \
      --enable CONFIG_DEVTMPFS_MOUNT \
      --enable CONFIG_TMPFS \
      --enable CONFIG_EXT4_FS \
      --enable CONFIG_F2FS_FS \
      --enable CONFIG_BTRFS_FS \
      --enable CONFIG_WIRELESS \
      --enable CONFIG_CFG80211 \
      --enable CONFIG_MAC80211
    make olddefconfig
    # Compile
    make '"$MAKEFLAGS"' bzImage modules
  "
'

# --- 5. Install modules + kernel image --------------------------------------
orion_run_stage "install-modules" "install modules to $LFS/lib/modules" -- bash -c '
  orion_chroot "
    set -e
    cd /sources/linux-'"$KERNEL_VERSION"'
    make INSTALL_MOD_PATH=/ modules_install
  "
  # Strip the build tree symlink so the modules tree is portable
  rm -f '"$LFS"'/lib/modules/*/build '"$LFS"'/lib/modules/*/source
'

orion_run_stage "install-kernel" "install kernel image + System.map + config" -- bash -c '
  set -e
  v='"$KERNEL_VERSION"'
  src='"$ORION_SOURCES"'/linux-$v
  install -Dm0644 "$src/System.map"          '"$LFS"'/boot/System.map-$v
  install -Dm0644 "$src/.config"             '"$LFS"'/boot/config-$v
  if [[ "'"$ORION_ARCH"'" == x86_64 ]]; then
    install -Dm0644 "$src/arch/x86/boot/bzImage" '"$LFS"'/boot/vmlinuz-$v
  else
    install -Dm0644 "$src/arch/arm64/boot/Image" '"$LFS"'/boot/vmlinuz-$v
  fi
  # Symlinks
  ln -sf vmlinuz-$v '"$LFS"'/boot/vmlinuz
  ln -sf System.map-$v '"$LFS"'/boot/System.map
  ln -sf config-$v '"$LFS"'/boot/config
  # EFI Linux image (for aarch64 / UEFI x86_64)
  if [[ "'"$ORION_ARCH"'" == aarch64 ]]; then
    mkdir -p '"$LFS"'/boot/EFI/BOOT
    cp "$src/arch/arm64/boot/Image" '"$LFS"'/boot/EFI/BOOT/Image
  fi
'

orion_log "stage 05 complete — kernel ${KERNEL_VERSION} installed for $ORION_ARCH"
# vim: set ts=2 sw=2 noet:
