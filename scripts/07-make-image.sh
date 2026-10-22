#!/usr/bin/env bash
# scripts/07-make-image.sh
#
# Stage 07 — package the finished $LFS tree into a deliverable.
#
# Two output formats:
#
#   - rootfs tarball (.tar.xz) — for use with the installer / cloud images
#   - netinst squashfs ISO     — bootable live + installer image
#
# The live ISO uses a layered overlay filesystem:
#   squashfs(rootfs)  ->  tmpfs(rw overlay)  ->  /
# The installer writes the (uncompressed) rootfs tarball to the target disk.
#
# This script is also called from the Docker entrypoint as the last step
# of a CI build.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="07-make-image"
orion_banner

# CLI args (used when invoked from Makefile with --arch --version)
ARCH="${1:-$ORION_ARCH}"
VERSION="${2:-$ORION_VERSION}"
OUT_DIR="${3:-$PWD/out}"
LFS_DIR="${4:-$LFS}"

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/orion-rootfs-$ARCH-$VERSION.tar.xz"

# -----------------------------------------------------------------------------
# Stage bodies as functions (cleaner than bash -c '...')
# -----------------------------------------------------------------------------

stage_clean_pre_pack() {
  set -e
  # Remove build trees
  rm -rf "$LFS_DIR"/sources/*-build "$LFS_DIR"/sources/*.tar.*
  # Clean apt-like caches if any crept in
  rm -rf "$LFS_DIR"/var/cache/* "$LFS_DIR"/var/log/*.log
  # Remove broken absolute symlinks created during build
  find "$LFS_DIR"/usr/bin "$LFS_DIR"/usr/sbin -xtype l -delete 2>/dev/null || true
  # Empty /tmp
  rm -rf "$LFS_DIR"/tmp/*
  # /proc /sys should not be mounted when packing
  for sub in proc sys dev dev/pts dev/shm run; do
    if mountpoint -q "$LFS_DIR/$sub"; then
      echo "WARN: $LFS_DIR/$sub still mounted — unmounting"
      umount -R "$LFS_DIR/$sub"
    fi
  done
}

stage_manifest() {
  set -e
  mkdir -p "$LFS_DIR/usr/share/orion"
  cat > "$LFS_DIR/usr/share/orion/rootfs.manifest" <<EOF
# Orion Linux rootfs manifest
name=Orion Linux
version=$VERSION
arch=$ARCH
book=LFS 12.3 + BLFS 12.3
init=systemd
pkg_manager=orion-pkg
kernel=${LFS_VERSIONS[linux]}
glibc=${LFS_VERSIONS[glibc]}
gcc=${LFS_VERSIONS[gcc]}
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host=$(hostname)
build_user=$USER
EOF
}

stage_tarball() {
  set -e
  cd "$LFS_DIR"
  XZ_OPT="-T0 -9" tar --create \
    --xattrs --xattrs-include="*" \
    --sort=name \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./dev \
    --exclude=./run \
    --exclude=./tmp \
    --exclude=./out \
    --file - \
    . | xz -T0 -9 > "$TARBALL"
  ls -la "$TARBALL"
}

stage_squashfs() {
  set -e
  mkdir -p "$OUT_DIR/live"
  mksquashfs "$TARBALL" "$OUT_DIR/live/rootfs.squashfs" \
    -comp zstd -Xcompression-level 19 -no-progress -no-exports \
    -no-xattrs -b 1M -noappend
  test -s "$OUT_DIR/live/rootfs.squashfs"
  ls -la "$OUT_DIR/live/rootfs.squashfs"
}

stage_iso() {
  set -e
  local iso="$OUT_DIR/Orion-Linux-$VERSION-$ARCH-netinst.iso"
  local work; work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN
  mkdir -p "$work"/isoroot/{EFI/BOOT,boot/grub,live}

  # Live rootfs
  cp "$OUT_DIR/live/rootfs.squashfs" "$work"/isoroot/live/
  # Kernel + config
  cp "$LFS_DIR"/boot/vmlinuz "$work"/isoroot/boot/ 2>/dev/null || \
    cp "$LFS_DIR"/boot/vmlinuz-* "$work"/isoroot/boot/vmlinuz
  cp "$LFS_DIR"/boot/System.map* "$work"/isoroot/boot/ 2>/dev/null || true
  cp "$LFS_DIR"/boot/config-*    "$work"/isoroot/boot/ 2>/dev/null || true
  if [[ -f "$LFS_DIR"/boot/initrd.img-* ]]; then
    cp "$LFS_DIR"/boot/initrd.img-* "$work"/isoroot/boot/initrd.img
  fi

  # Grub config for the ISO
  cat > "$work"/isoroot/boot/grub/grub.cfg <<GRUBCFG
set default="0"
set timeout=10
insmod all_video
insmod part_gpt
insmod part_msdos
insmod squashfs
insmod loopback
insmod linux

menuentry "Orion Linux $VERSION ($ARCH) - Install" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.show_status=1 loglevel=3 \
        orion.installer=1
    initrd /boot/initrd.img
}

menuentry "Orion Linux $VERSION ($ARCH) - Live" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.show_status=1 loglevel=3
    initrd /boot/initrd.img
}

menuentry "Orion Linux $VERSION ($ARCH) - Recovery" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.unit=rescue.target loglevel=3
    initrd /boot/initrd.img
}
GRUBCFG

  # Build EFI boot image for both arches
  if [[ "$ARCH" == "x86_64" ]]; then
    grub-mkstandalone --grub-mkimage=/usr/bin/grub-mkimage \
      --fonts="unicode" --themes="" \
      --boot-directory="$work"/isoroot/boot \
      --format=x86_64-efi \
      -o "$work"/bootx64.efi \
      "boot/grub/grub.cfg=$work/isoroot/boot/grub/grub.cfg"
    install -Dm0644 "$work"/bootx64.efi "$work"/isoroot/EFI/BOOT/bootx64.efi
  else
    grub-mkstandalone \
      --boot-directory="$work"/isoroot/boot \
      --format=arm64-efi \
      -o "$work"/bootaa64.efi \
      "boot/grub/grub.cfg=$work/isoroot/boot/grub/grub.cfg"
    install -Dm0644 "$work"/bootaa64.efi "$work"/isoroot/EFI/BOOT/bootaa64.efi
  fi

  # Build an ESP image for El Torito EFI boot
  dd if=/dev/zero of="$work"/efi.img bs=1M count=64 status=none
  mformat -i "$work"/efi.img -N -F ::
  if [[ "$ARCH" == "x86_64" ]]; then
    mcopy -i "$work"/efi.img "$work"/isoroot/EFI/BOOT/bootx64.efi ::EFI/BOOT/bootx64.efi
  else
    mcopy -i "$work"/efi.img "$work"/isoroot/EFI/BOOT/bootaa64.efi ::EFI/BOOT/bootaa64.efi
  fi
  cp "$work"/efi.img "$work"/isoroot/efi.img

  # Assemble the ISO with xorriso (hybrid: BIOS + EFI on x86_64; EFI-only on aarch64)
  xorriso -as mkisofs \
    -r -V "ORION_LINUX_$VERSION" \
    -J -joliet-long \
    -input-charset utf-8 \
    -e efi.img -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e efi.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$iso" \
    "$work"/isoroot

  ls -la "$iso"
}

# --- Run stages ------------------------------------------------------------
orion_run_stage "clean-pre-pack" "remove build cruft before packing" -- stage_clean_pre_pack
orion_run_stage "manifest"        "write rootfs.manifest"             -- stage_manifest
orion_run_stage "tarball"         "create $TARBALL"                   -- stage_tarball
orion_run_stage "squashfs"        "compress rootfs into squashfs"     -- stage_squashfs
orion_run_stage "iso"             "build bootable netinst ISO"        -- stage_iso

orion_log "stage 07 complete — ISO + tarball at $OUT_DIR"
# vim: set ts=2 sw=2 noet:
