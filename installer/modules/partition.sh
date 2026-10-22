#!/usr/bin/env bash
# installer/modules/partition.sh
#
# Step 2: disk selection + partition layout.
#
# Layout (default):
#   - GPT partition table
#   - partition 1: 1 MiB BIOS boot partition (for grub-install on BIOS systems)
#   - partition 2: 512 MiB EFI system partition (FAT32, /boot/efi)
#   - partition 3: swap (default 2 GiB; user-configurable)
#   - partition 4: root (rest of the disk, ext4 by default)
#
# On aarch64, the same layout is used but partition 1 is omitted (no BIOS).
# On SBCs (e.g. Raspberry Pi), the user is expected to override with a custom
# layout — see docs/INSTALL.md.

installer_module_partition() {
  local disks=()
  while read -r name _ _ size _; do
    disks+=("/dev/$name" "$size $(_)")
  done < <(lsblk -dnpo NAME,TYPE,SIZE,MODEL | grep -v loop | awk '$2=="disk"{print $1, $4, $5}')

  (( ${#disks[@]} > 0 )) || die "no disks detected"

  local disk
  disk=$(whip --title "Target disk" --menu "Choose the disk to install Orion Linux on. \
    THIS WILL WIPE THE DISK." \
        $ROWS $COLS $(( ${#disks[@]} / 2 )) "${disks[@]}" \
        3>&1 1>&2 2>&3) || die "no disk selected"
  STATE[disk]="$disk"

  # Confirm wipe
  whip --title "Confirm" --yesno \
    "This will WIPE $disk. Are you absolutely sure?" \
    $ROWS $COLS -- 3>&1 1>&2 2>&3 \
    || die "aborted by user"

  # Get swap size
  local swap_mb
  swap_mb=$(whip --title "Swap size" --inputbox "Swap size in MiB (0 = no swap)" \
        $ROWS $COLS "${STATE[swap_mb]}" 3>&1 1>&2 2>&3 || echo 2048)
  STATE[swap_mb]="$swap_mb"

  local root_fs
  root_fs=$(whip --title "Root filesystem" --menu "Choose root filesystem" \
        $ROWS $COLS 4 \
        "ext4" "ext4 (recommended, journaling)" \
        "f2fs" "f2fs (good for SSD + flash)" \
        "btrfs" "btrfs (CoW, snapshots)" \
        "xfs" "xfs (high perf, no shrink)" \
        3>&1 1>&2 2>&3 || echo ext4)
  STATE[root_fs]="$root_fs"

  log "wiping $disk and creating partition table"
  sgdisk --zap-all --clear "${STATE[disk]}"
  # Wait for kernel to re-read the partition table
  partprobe "${STATE[disk]}" 2>/dev/null || sleep 2

  # Partition numbering:
  #   x86_64:  p1=BIOS boot (1MiB), p2=ESP (512MiB), p3=swap (optional), p4=root
  #   aarch64: p2=ESP (512MiB), p3=swap (optional), p4=root (p1 unused)
  local p1="" p2 p3="" p4
  local next_part=1
  if [[ "${ORION_ARCH:-$(uname -m)}" == "x86_64" ]]; then
    # BIOS boot partition (1 MiB) for grub-install when hybrid
    sgdisk --new=1:0:+1M --typecode=1:EF02 \
           --change-name=1:"BIOS boot" "${STATE[disk]}"
    p1=1
    next_part=2
  fi
  # EFI system partition
  p2=$next_part
  sgdisk --new="$p2:0:+512M" --typecode="$p2:EF00" \
         --change-name="$p2:EFI System" "${STATE[disk]}"
  next_part=$(( p2 + 1 ))
  # Swap (optional)
  if (( swap_mb > 0 )); then
    p3=$next_part
    sgdisk --new="$p3:0:+${swap_mb}M" --typecode="$p3:8200" \
           --change-name="$p3:Linux swap" "${STATE[disk]}"
    next_part=$(( p3 + 1 ))
  fi
  # Root (rest of disk)
  p4=$next_part
  sgdisk --new="$p4:0:0" --typecode="$p4:8300" \
         --change-name="$p4:Linux root" "${STATE[disk]}"

  partprobe "${STATE[disk]}" 2>/dev/null || sleep 2

  # Format
  log "formatting partitions"
  local efi_dev="${STATE[disk]}"
  [[ "${STATE[disk]}" =~ nvme|mmcblk ]] && efi_dev="${STATE[disk]}p"
  mkfs.vfat -F32 -n EFI "${efi_dev}${p2}"
  if [[ -n "$p3" ]] && (( swap_mb > 0 )); then
    mkswap -L SWAP "${STATE[disk]}${p1:+p}${p3}"
  fi
  case "$root_fs" in
    ext4)  mkfs.ext4 -L orionroot -F "${STATE[disk]}${p1:+p}$p4" ;;
    f2fs)  mkfs.f2fs -f -l orionroot "${STATE[disk]}${p1:+p}$p4" ;;
    btrfs) mkfs.btrfs -L orionroot -f "${STATE[disk]}${p1:+p}$p4" ;;
    xfs)   mkfs.xfs -L orionroot -f "${STATE[disk]}${p1:+p}$p4" ;;
  esac

  # Mount
  log "mounting target at /mnt/orion"
  mkdir -p /mnt/orion
  mount "${STATE[disk]}${p1:+p}$p4" /mnt/orion
  mkdir -p /mnt/orion/boot/efi
  mount "${efi_dev}${p2}" /mnt/orion/boot/efi
  if [[ -n "$p3" ]] && (( swap_mb > 0 )); then
    swapon "${STATE[disk]}${p1:+p}$p3" || true
  fi

  # Save partition info for fstab generation later
  STATE[part_efi]="${efi_dev}${p2}"
  STATE[part_root]="${STATE[disk]}${p1:+p}$p4"
  STATE[part_swap]="${p3:+${STATE[disk]}${p1:+p}$p3}"
  STATE[part_swap_size]="$swap_mb"

  ok "partitions created and mounted"
}
