#!/usr/bin/env bash
# installer/modules/extract_rootfs.sh
#
# Step 3a: extract the Orion Linux rootfs tarball onto the new root.
#
# Source priority:
#   1. /run/orion/rootfs.tar.xz (from netinst boot payload)
#   2. /var/orion/cache/orion-rootfs-*.tar.xz (live ISO squashfs payload)
#   3. A user-supplied path (prompt)

installer_module_extract_rootfs() {
  local src=""
  # 1. netinst payload
  if [[ -f /run/orion/rootfs.tar.xz ]]; then
    src=/run/orion/rootfs.tar.xz
  # 2. cached on the live ISO
  elif ls /var/orion/cache/orion-rootfs-*.tar.xz >/dev/null 2>&1; then
    src=$(ls /var/orion/cache/orion-rootfs-*.tar.xz | head -1)
  else
    src=$(whip --title "Rootfs" --inputbox \
        "Path to the Orion rootfs tarball (absolute path)" \
        $ROWS $COLS "/dev/sr0" 3>&1 1>&2 2>&3 || echo "")
  fi
  [[ -n "$src" ]] || die "no rootfs source available"
  [[ -f "$src" ]] || die "rootfs not found: $src"

  log "extracting rootfs from $src to /mnt/orion"
  tar --extract --xattrs --xattrs-include="*" --keep-going \
      --file "$src" -C /mnt/orion 2>&1 | head -100 || true
  ok "rootfs extracted"
}
