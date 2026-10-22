#!/usr/bin/env bash
# scripts/08-release-artifacts.sh
#
# Stage 08 — produce release-grade artifacts.
#
# Usage:
#   scripts/08-release-artifacts.sh iso  --arch ARCH --version V --rootfs FILE --out DIR
#   scripts/08-release-artifacts.sh img  --arch ARCH --version V --rootfs FILE --out DIR
#
# This script is invoked from the Makefile `iso` and `img` targets and
# from CI. It does NOT rebuild the rootfs — it wraps a finished tarball
# into a deliverable.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

orion_current_stage="08-release"

# --- arg parsing ------------------------------------------------------------
ACTION=""
ARCH="${ORION_ARCH:-}"
VERSION="${ORION_VERSION:-}"
ROOTFS=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    iso|img) ACTION="$1"; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --rootfs) ROOTFS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ACTION" ]] || { echo "missing action (iso|img)" >&2; exit 2; }
[[ -n "$ARCH" ]]    || { echo "missing --arch" >&2; exit 2; }
[[ -n "$VERSION" ]] || { echo "missing --version" >&2; exit 2; }
[[ -n "$ROOTFS" ]]  || { echo "missing --rootfs" >&2; exit 2; }
[[ -n "$OUT" ]]     || { echo "missing --out" >&2; exit 2; }
[[ -f "$ROOTFS" ]]  || { echo "rootfs not found: $ROOTFS" >&2; exit 2; }

mkdir -p "$OUT"
orion_log "release: $ACTION arch=$ARCH version=$VERSION"

# ---------------------------------------------------------------------------
# iso  — wrap a rootfs tarball into a bootable netinst ISO
# ---------------------------------------------------------------------------
do_iso() {
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local isodir="$tmp/isoroot"
  mkdir -p "$isodir"/{EFI/BOOT,boot/grub,live}

  # Live layer: extract rootfs tarball into a squashfs
  local rootfs_dir="$tmp/rootfs"
  mkdir -p "$rootfs_dir"
  orion_log "extracting rootfs tarball"
  tar --extract --xattrs --xattrs-include="*" --file "$ROOTFS" -C "$rootfs_dir"

  orion_log "compressing into squashfs (this takes a few minutes)"
  mksquashfs "$rootfs_dir" "$isodir/live/rootfs.squashfs" \
    -comp zstd -Xcompression-level 19 -no-progress -no-exports -no-xattrs -b 1M -noappend

  # Copy kernel
  orion_log "copying kernel"
  cp "$rootfs_dir"/boot/vmlinuz         "$isodir"/boot/vmlinuz 2>/dev/null || \
    cp "$rootfs_dir"/boot/vmlinuz-*     "$isodir"/boot/vmlinuz
  cp "$rootfs_dir"/boot/System.map*     "$isodir"/boot/ 2>/dev/null || true
  cp "$rootfs_dir"/boot/config-*        "$isodir"/boot/ 2>/dev/null || true
  # Initrd (if dracut ran during build) else synthesize a tiny one
  # [[ -f *.foo ]] doesn't work in bash — the glob isn't expanded inside [[ ]].
  # Use a shell glob via ls + head to find the first match.
  local _initrd
  _initrd=$(ls "$rootfs_dir"/boot/initrd.img-* 2>/dev/null | head -1 || true)
  if [[ -n "$_initrd" ]]; then
    cp "$_initrd" "$isodir"/boot/initrd.img
  fi

  # Grub config for ISO
  cat > "$isodir"/boot/grub/grub.cfg <<EOF
set default="0"
set timeout=10
insmod all_video
insmod part_gpt
insmod part_msdos
insmod squashfs
insmod loopback
insmod linux

menuentry "Orion Linux $VERSION ($ARCH) — Install" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.show_status=1 loglevel=3 \
        orion.installer=1
    initrd /boot/initrd.img
}

menuentry "Orion Linux $VERSION ($ARCH) — Live" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.show_status=1 loglevel=3
    initrd /boot/initrd.img
}

menuentry "Orion Linux $VERSION ($ARCH) — Recovery" {
    linux /boot/vmlinuz root=live:LABEL=ORION_LINUX ro \
        systemd.unit=rescue.target loglevel=3
    initrd /boot/initrd.img
}
EOF

  # Build EFI bootloader for the ISO
  orion_log "building grub EFI image for $ARCH"
  if [[ "$ARCH" == "x86_64" ]]; then
    grub-mkstandalone --grub-mkimage="$(command -v grub-mkimage)" \
      --fonts="unicode" --themes="" \
      --boot-directory="$isodir"/boot \
      --format=x86_64-efi \
      -o "$tmp"/bootx64.efi \
      "boot/grub/grub.cfg=$isodir/boot/grub/grub.cfg"
    install -Dm0644 "$tmp"/bootx64.efi "$isodir"/EFI/BOOT/bootx64.efi
  else
    grub-mkstandalone \
      --boot-directory="$isodir"/boot \
      --format=arm64-efi \
      -o "$tmp"/bootaa64.efi \
      "boot/grub/grub.cfg=$isodir/boot/grub/grub.cfg"
    install -Dm0644 "$tmp"/bootaa64.efi "$isodir"/EFI/BOOT/bootaa64.efi
  fi

  # Build an ESP image for El Torito EFI boot
  orion_log "creating EFI system partition image"
  dd if=/dev/zero of="$tmp"/efi.img bs=1M count=64 status=none
  mformat -i "$tmp"/efi.img -N -F ::
  if [[ "$ARCH" == "x86_64" ]]; then
    mcopy -i "$tmp"/efi.img "$isodir"/EFI/BOOT/bootx64.efi ::EFI/BOOT/bootx64.efi
  else
    mcopy -i "$tmp"/efi.img "$isodir"/EFI/BOOT/bootaa64.efi ::EFI/BOOT/bootaa64.efi
  fi
  cp "$tmp"/efi.img "$isodir"/efi.img

  # Assemble the ISO with xorriso (hybrid: BIOS + EFI)
  local iso="$OUT/Orion-Linux-$VERSION-$ARCH-netinst.iso"
  orion_log "assembling ISO: $iso"
  xorriso -as mkisofs \
    -r -V "ORION_LINUX_$VERSION" \
    -J -joliet-long \
    -input-charset utf-8 \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null || \
    -e efi.img -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e efi.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$iso" \
    "$isodir"

  # Checksums for the release page
  ( cd "$OUT" && sha256sum "$(basename "$iso")" > "$(basename "$iso")".sha256 )

  orion_log "ISO ready: $iso"
  orion_log "sha256: $OUT/$(basename "$iso").sha256"
}

# ---------------------------------------------------------------------------
# img  — write rootfs into a flashable disk image (mostly for ARM SBCs)
# ---------------------------------------------------------------------------
do_img() {
  local size_mb=4096   # 4 GB image — large enough for the full rootfs + room
  local img="$OUT/Orion-Linux-$VERSION-$ARCH.img"

  orion_log "creating $size_mb MiB disk image: $img"
  dd if=/dev/zero of="$img" bs=1M count=0 seek="$size_mb" status=none
  # Partition: 1× GPT, 1 partition, root partition starts at sector 2048
  sgdisk --clear \
         --new=1:2048:0 \
         --typecode=1:8300 \
         --change-name=1:"ORION_ROOT" \
         "$img"
  # Loop-mount the partition
  local part; part=$(losetup -fP --show "$img")
  orion_log "formatting /dev/loop (partition: $part p1) as ext4"
  mkfs.ext4 -L ORION_ROOT -F "${part}p1"
  # Mount + extract rootfs
  local mnt; mnt=$(mktemp -d)
  mount "${part}p1" "$mnt"
  orion_log "extracting rootfs"
  tar --extract --xattrs --xattrs-include="*" --file "$ROOTFS" -C "$mnt"
  # Install bootloader (per-arch)
  orion_log "installing bootloader to image"
  if [[ "$ARCH" == "x86_64" ]]; then
    mount --bind /dev  "$mnt"/dev
    mount -t proc proc "$mnt"/proc
    mount -t sysfs sys "$mnt"/sys
    chroot "$mnt" grub-install --target=i386-pc --boot-directory=/boot "$part" || true
    chroot "$mnt" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --boot-directory=/boot --removable || true
    chroot "$mnt" grub-mkconfig -o /boot/grub/grub.cfg || true
    umount -R "$mnt"/dev "$mnt"/proc "$mnt"/sys
  else
    # ARM SBC: write U-Boot at sector 64 (most boards)
    # The actual U-Boot binary lives at /usr/lib/u-boot/<board>/u-boot.bin
    # The user is expected to have selected a board via env var.
    if [[ -n "${ORION_UBOOT_BIN:-}" && -f "${ORION_UBOOT_BIN:-}" ]]; then
      dd if="$ORION_UBOOT_BIN" of="$part" bs=1024 seek=8 conv=notrunc status=none
      orion_info "wrote U-Boot from $ORION_UBOOT_BIN"
    else
      orion_warn "no ORION_UBOOT_BIN set — image will not boot on ARM SBCs without firmware"
      orion_warn "  typical example: ORION_UBOOT_BIN=/usr/lib/u-boot/rpi_4/u-boot.bin"
    fi
    # grub-efi for generic UEFI ARM
    mkdir -p "$mnt"/boot/efi/EFI/BOOT
    if [[ -f "$mnt"/boot/EFI/BOOT/bootaa64.efi ]]; then
      orion_info "grub-efi already in place at /boot/EFI/BOOT"
    fi
  fi
  umount "$mnt"
  losetup -d "$part"
  rm -rf "$mnt"

  # Compress
  orion_log "compressing image (zstd)"
  zstd -19 -T0 "$img" -f -o "$img.zst"
  ( cd "$OUT" && sha256sum "$(basename "$img").zst" > "$(basename "$img").zst.sha256" )

  orion_log "image ready: $img.zst"
}

# --- dispatch ---------------------------------------------------------------
case "$ACTION" in
  iso) do_iso ;;
  img) do_img ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac

orion_log "stage 08 complete"
# vim: set ts=2 sw=2 noet:
