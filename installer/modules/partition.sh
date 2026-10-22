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

  local p1="" p2="" p3="" p4=""
  if [[ "${ORION_ARCH:-$(uname -m)}" == "x86_64" ]]; then
    # BIOS boot partition (1 MiB) for grub-install when hybrid
    sgdisk --new=1:0:+1M --typecode=1:EF02 \
           --change-name=1:"BIOS boot" "${STATE[disk]}"
    p1=1
  fi
  # EFI system partition
  sgdisk --new=$(( ${p1:+${p1}+1} 2 )):0:+512M --typecode=2:EF00 \
         --change-name=2:"EFI System" "${STATE[disk]}"
  p2=$(( ${p1:+${p1}+1} 2 ))
  # Swap
  if (( swap_mb > 0 )); then
    sgdisk --new=$(( p2+1 )):0:+${swap_mb}M --typecode=$(( p2+1 )):8200 \
           --change-name=$(( p2+1 )):"Linux swap" "${STATE[disk]}"
    p3=$(( p2+1 ))
  else
    p3=""
  fi
  # Root (rest of disk)
  sgdisk --new=$(( ${p3:-$p2}+1 )):0:0 --typecode=$(( ${p3:-$p2}+1 )):8300 \
         --change-name=$(( ${p3:-$p2}+1 )):"Linux root" "${STATE[disk]}"
  p4=$(( ${p3:-$p2}+1 ))

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
