# Install guide

How to install Orion Linux to a real disk, from the netinst ISO or from
a rootfs tarball.

## Option A — install from the netinst ISO

### 1. Get the ISO

Download from the
[Releases page](https://github.com/likus-69/Orion-Linux/releases). Pick
the file matching your arch:

- `Orion-Linux-<version>-x86_64-netinst.iso` (Intel/AMD)
- `Orion-Linux-<version>-aarch64-netinst.iso` (ARM 64)

Verify the checksum:

```bash
echo "$(cat Orion-Linux-*.iso.sha256 | awk '{print $1}')  Orion-Linux-*.iso" | sha256sum -c
```

### 2. Flash to USB

On Linux:

```bash
sudo dd if=Orion-Linux-<version>-x86_64-netinst.iso \
  of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

On macOS, replace `/dev/sdX` with `/dev/rdiskN` (use `diskutil list`
to find N first).

On Windows, use [Rufus](https://rufus.ie/) or [balenaEtcher](https://etcher.balena.io/).

### 3. Boot the USB

- **x86_64**: most BIOSes will boot the USB automatically. Press F12
  (Lenovo/Dell), F9 (HP), or your motherboard's boot menu key. Disable
  Secure Boot if you see "Verification failed: (15) Access Denied" —
  Orion's bootloader is unsigned in v0.1.
- **aarch64**: depends on the board. For Raspberry Pi, the ISO won't
  boot directly — use the `.img.zst` flashable image instead (Option B
  below). For generic UEFI ARM machines (Ampere VM, AVA-Developer
  platforms), the ISO should boot.

### 4. Run the installer

When the live system boots, you'll see a root shell with a banner.
Run:

```bash
orion-installer
```

The wizard walks through:

1. **Language, keymap, timezone** — pick from a menu
2. **Disk selection + partitioning** — pick a disk, set swap size,
   pick filesystem (ext4 / f2fs / btrfs / xfs)
3. **Base system install** — extracts the rootfs tarball (~5–10 min)
4. **Hostname, root password, user creation** — sets up users
5. **Desktop environment** — pick GNOME / KDE / XFCE / none
6. **Bootloader install** — GRUB to MBR + ESP
7. **Finalize** — generate fstab, initramfs, unmount

Reboot when prompted: `systemctl reboot`. Remove the USB when you see
GRUB.

## Option B — flash the disk image (ARM SBCs)

For Raspberry Pi 4/5, Pinebook, etc., the netinst ISO usually doesn't
boot directly because the board firmware expects a specific partition
layout. Use the pre-built disk image instead.

```bash
# Decompress
zstd -d Orion-Linux-<version>-aarch64.img.zst

# Flash to SD card (find the right /dev/sdX first with lsblk)
sudo dd if=Orion-Linux-<version>-aarch64.img \
  of=/dev/sdX bs=4M status=progress conv=fsync
sync

# Insert into the SBC and boot
```

On first boot you'll land at the root shell. Run `orion-installer` to
re-partition the disk, install the bootloader, and pick a desktop.

> Note for Raspberry Pi 5 specifically: the v0.1 image may not include
> the `bcm2712` U-Boot binary. Set
> `ORION_UBOOT_BIN=/usr/lib/u-boot/rpi_5/u-boot.bin` in the installer
> environment if `orion-installer` warns that U-Boot is missing.

## Option C — install from a rootfs tarball (no ISO)

If you've built the rootfs locally with `make build` and want to
install it without burning an ISO, you can run the installer directly:

```bash
# Boot any live Linux (any distro)
sudo mount /dev/sda1 /mnt/target      # your target root partition
sudo tar -xf orion-rootfs-x86_64-dev.tar.xz -C /mnt/target
sudo mount --bind /dev  /mnt/target/dev
sudo mount -t proc proc /mnt/target/proc
sudo mount -t sysfs sys /mnt/target/sys
sudo chroot /mnt/target /usr/bin/orion-installer
```

The installer's modules expect `/mnt/orion` as the chroot; symlink it:

```bash
sudo ln -sfn /mnt/target /mnt/orion
```

## Post-install configuration

After the first boot of the installed system:

### 1. Update package repo + upgrade

```bash
sudo orion-pkg update
sudo orion-pkg upgrade
```

### 2. Install a desktop if you skipped it

```bash
sudo orion-pkg install $(cat /usr/share/orion/de-profiles/xfce.list)
sudo systemctl enable lightdm
sudo systemctl set-default graphical.target
sudo systemctl isolate graphical.target
```

### 3. Networking

`systemd-networkd` is enabled by default. To configure a wired interface:

```bash
sudo cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=eth0  # or enp3s0, or your interface name (ip a to find it)

[Network]
DHCP=yes
EOF
sudo systemctl restart systemd-networkd
```

For WiFi, `iwd` is the backend:

```bash
sudo systemctl enable --now iwd
iwctl device list                              # find your wlanX
iwctl station wlan0 scan
iwctl station wlan0 connect "YourSSID"          # then type the password
```

### 4. Time sync

`systemd-timesyncd` is enabled. Verify with `timedatectl`. To set
the timezone after install:

```bash
sudo timedatectl set-timezone Africa/Kampala
```

### 5. Adding a new user

```bash
sudo useradd -m -G wheel -s /bin/bash newuser
sudo passwd newuser
```

The `wheel` group grants `sudo` access (configured by stage 04).

## Recovery

If the system fails to boot, you can:

1. Boot the netinst ISO again
2. Mount the root partition at `/mnt/orion`:
   ```bash
   sudo mount /dev/sda3 /mnt/orion
   sudo mount /dev/sda2 /mnt/orion/boot/efi   # if UEFI
   sudo arch-chroot /mnt/orion    # if arch-chroot is available
   # or:
   sudo mount --bind /dev /mnt/orion/dev
   sudo mount -t proc proc /mnt/orion/proc
   sudo mount -t sysfs sys /mnt/orion/sys
   sudo chroot /mnt/orion /bin/bash
   ```
3. Inside the chroot, fix whatever broke, then `exit` and `reboot`.

## Uninstalling

There's no uninstaller — Orion Linux boots from its own partition. To
remove it:

1. Boot another distro's live USB
2. Delete the Orion partition(s) with `fdisk` / `gdisk` / `parted`
3. Re-install GRUB from your other distro:
   ```bash
   sudo mount /dev/sdaN /mnt            # your other distro's root
   sudo mount /dev/sda1 /mnt/boot/efi    # ESP
   sudo arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi
   sudo arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
   ```
