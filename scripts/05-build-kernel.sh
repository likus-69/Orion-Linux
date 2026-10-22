#!/usr/bin/env bash
# scripts/05-build-kernel.sh
#
# Stage 05 — build the Linux kernel for $ORION_ARCH.
#
# Two defconfigs are shipped in this repo:
#   packages/linux/config-x86_64  — typical desktop/laptop kernel
#   packages/linux/config-aarch64 — generic ARM (works on most SBCs + VMs)
#
# For SBC-specific builds (e.g. Raspberry Pi 5), set
#   ORION_KERNEL_DEFCONFIG=bcm2712 in the environment before invoking this.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="05-kernel"
orion_banner

# --- 1. Fetch + extract -----------------------------------------------------
orion_run_stage "fetch" "download linux ${LFS_VERSIONS[linux]} source" -- bash -c '
  cd '"$ORION_SOURCES"'
  orion_fetch https://www.kernel.org/pub/linux/kernel/v6.x/linux-'"${LFS_VERSIONS[linux]}"'.tar.xz
  rm -rf linux-'"${LFS_VERSIONS[linux]}"'
  tar xf linux-'"${LFS_VERSIONS[linux]}"'.tar.xz
  chown -R root:root linux-'"${LFS_VERSIONS[linux]}"'
'

# --- 2. Pick a defconfig ------------------------------------------------------
orion_run_stage "defconfig" "select kernel defconfig for $ORION_ARCH" -- bash -c '
  case "'"$ORION_ARCH"'" in
    x86_64)  cfg=packages/linux/config-x86_64 ;;
    aarch64) cfg=packages/linux/config-aarch64 ;;
    *) orion_die "unsupported arch: '"$ORION_ARCH"'" ;;
  esac
  cp "$cfg" '"$ORION_SOURCES"'/linux-'"${LFS_VERSIONS[linux]}"'/.config
  echo "    using $cfg"
'

# --- 3. Build inside chroot -------------------------------------------------
orion_run_stage "build" "build kernel + modules" -- bash -c '
  orion_chroot "
    set -e
    cd /sources/linux-'"${LFS_VERSIONS[linux]}"'
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

# --- 4. Install modules + kernel image --------------------------------------
orion_run_stage "install-modules" "install modules to $LFS/lib/modules" -- bash -c '
  orion_chroot "
    set -e
    cd /sources/linux-'"${LFS_VERSIONS[linux]}"'
    make INSTALL_MOD_PATH=/ modules_install
  "
  # Strip the build tree symlink so the modules tree is portable
  rm -f '"$LFS"'/lib/modules/*/build '"$LFS"'/lib/modules/*/source
'

orion_run_stage "install-kernel" "install kernel image + System.map + config" -- bash -c '
  set -e
  v='"${LFS_VERSIONS[linux]}"'
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

orion_log "stage 05 complete — kernel ${LFS_VERSIONS[linux]} installed for $ORION_ARCH"
# vim: set ts=2 sw=2 noet:
