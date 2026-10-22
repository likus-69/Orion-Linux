#!/usr/bin/env bash
# installer/modules/install_bootloader.sh
#
# Step 6: install the bootloader on the target disk.
#
#   - x86_64:   GRUB 2 BIOS (i386-pc) + UEFI (x86_64-efi) -- install both
#   - aarch64:  GRUB-EFI (arm64-efi)
#
# For ARM SBCs with U-Boot, an additional U-Boot binary may need to be
# written at sector 64 — this is a separate step handled by board-specific
# code if ORION_UBOOT_BIN is set.

installer_module_install_bootloader() {
  local target=/mnt/orion
  local disk="${STATE[disk]}"
  local arch="${ORION_ARCH:-$(uname -m)}"

  log "installing bootloader ($arch)"

  # Make sure /boot/efi is mounted (it should be, but be safe)
  if ! mountpoint -q "$target/boot/efi"; then
    mount "${STATE[part_efi]}" "$target/boot/efi" || \
      die "could not mount ESP at ${STATE[part_efi]}"
  fi

  # Install GRUB into the new rootfs
  case "$arch" in
    x86_64)
      log "installing grub-pc (BIOS) to $disk"
      chroot "$target" grub-install --target=i386-pc \
          --boot-directory=/boot --recheck "$disk" \
          2>&1 | info "grub-pc:" || warn "BIOS grub install failed"
      log "installing grub-efi (UEFI)"
      chroot "$target" grub-install --target=x86_64-efi \
          --efi-directory=/boot/efi \
          --bootloader-id=orion \
          --boot-directory=/boot --recheck \
          --removable 2>&1 | info "grub-efi:" \
          || warn "UEFI grub install failed (or already installed)"
      ;;
    aarch64)
      log "installing grub-efi (ARM64)"
      chroot "$target" grub-install --target=arm64-efi \
          --efi-directory=/boot/efi \
          --bootloader-id=orion \
          --boot-directory=/boot --recheck \
          --removable 2>&1 | info "grub-efi:" \
          || warn "ARM64 grub install failed"
      ;;
    *)
      die "unsupported arch for bootloader: $arch" ;;
  esac

  # U-Boot for ARM SBCs (optional, board-specific)
  if [[ "$arch" == "aarch64" && -n "${ORION_UBOOT_BIN:-}" ]]; then
    if [[ -f "$ORION_UBOOT_BIN" ]]; then
      log "writing U-Boot from $ORION_UBOOT_BIN to $disk (sector 64)"
      dd if="$ORION_UBOOT_BIN" of="$disk" bs=1024 seek=64 conv=notrunc status=none
      ok "U-Boot written"
    else
      warn "ORION_UBOOT_BIN points to a non-existent file — skipping"
    fi
  fi

  # Generate grub.cfg
  log "generating grub.cfg"
  chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | info "grub-mkconfig:" \
    || warn "grub-mkconfig failed — using the fallback template"

  ok "bootloader installed"
}
