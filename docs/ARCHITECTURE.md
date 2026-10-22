# Architecture

Orion Linux is built in **eight numbered stages** that map directly to the
LFS 12.3 book chapters. Each stage is a single bash script under
`scripts/NN-<name>.sh` that can be re-run independently — failures resume
cheaply because the source tree and built artifacts persist on disk
between stages.

```
                    ┌─────────────────────────────────────────────┐
                    │                                             │
   00-host-prepare ─┼─▶ user "orionlfs", /mnt/orion, sources       │
                    │                                             │
   01-cross-toolch. ┼─▶ /tools/bin/$LFS_TGT-{gcc,ld,as}             │
                    │                                             │
   02-temp-tools ────┼─▶ /tools/bin/{bash,make,tar,gawk,coreutils} │
                    │                                             │
   03-lfs-system ────┼─▶ /usr/{bin,lib,include,...} (real rootfs)  │
                    │                                             │
   04-config-system ─┼─▶ /etc/os-release, orion-pkg, installer, users│
                    │                                             │
   05-build-kernel ──┼─▶ /boot/vmlinuz, /lib/modules/<k>/           │
                    │                                             │
   06-build-bootldr ─┼─▶ /boot/grub/grub.cfg, /boot/EFI/BOOT/*     │
                    │                                             │
   07-make-image ────┼─▶ out/orion-rootfs-<arch>-<ver>.tar.xz       │
                    │                  + out/Orion-Linux-*.iso     │
                    │                                             │
   08-release-artifacts ─▶ final ISO / IMG + sha256sums           │
                    │                                             │
                    └─────────────────────────────────────────────┘
```

## Stage responsibilities

### Stage 00 — host prepare

Creates the unprivileged `orionlfs` user, lays out the `$LFS` mountpoint
at `/mnt/orion`, fetches the LFS 12.3 wget-list (used by stage 01 to know
which source tarballs to download), and writes the build environment file
`$LFS/etc/orion-env`. This stage is safe to re-run; it skips steps that
have already been done.

### Stage 01 — cross-toolchain

Builds the *temporary* toolchain that runs on the host but produces
binaries for the target triplet `$LFS_TGT` (= `$ARCH-orion-linux-gnu`).
This is the longest-running stage on first run (~3–4 hours on x86_64,
~8–12 hours under aarch64 QEMU emulation).

Build order (LFS chapter 5):

1. `binutils` pass 1 — assembler/linker for the target triplet
2. `gcc` pass 1 — C compiler only, no libc yet
3. `linux` API headers — needed so glibc knows what syscalls exist
4. `glibc` — the target C library, installed into `/usr`
5. `libstdc++` — from the gcc pass 1 tree, against the new glibc
6. `binutils` pass 2 — re-linked against the new glibc
7. `gcc` pass 2 — full C/C++ cross compiler

After stage 01, `/tools/bin/$LFS_TGT-gcc` can compile hello.c for the
target arch.

### Stage 02 — temp tools

Builds native versions of the essential build tools (bash, make, tar,
gawk, coreutils, sed, etc.) and installs them into `/tools`. The
toolchain itself is rebuilt natively in pass 3 here, producing a
self-hosting `gcc` and `binutils` that don't depend on the host's
libraries at all.

### Stage 03 — full LFS system

The big one. ~250 packages built inside `chroot $LFS` as root, using
`/tools/bin/*` as the bootstrap compiler. Each package is sourced from
`packages/<name>/build` and follows the same pattern: configure → make
→ `make install DESTDIR=...` → manifest.

Build order loosely follows LFS chapter 8 (libraries first, then tools,
then systemd, then user-facing packages). The list is hard-coded at the
top of `scripts/03-build-lfs-system.sh` as `LFS_PKGS=()`.

### Stage 04 — config system

Applies branding (`/etc/os-release`, motd, issue), generates locales,
sets the timezone, locks the root account, creates the unprivileged
`orion` user, enables systemd units (`systemd-networkd`,
`systemd-resolved`, `iwd`, `sshd`, `systemd-timesyncd`), and installs
both `orion-pkg` and `orion-installer` into `$LFS/usr/bin`.

This stage also seeds `/etc/skel` with sensible bash defaults so new
users get a reasonable shell experience out of the box.

### Stage 05 — kernel

Fetches the 6.12.4 mainline kernel source, picks the right defconfig
(`packages/linux/config-x86_64` or `config-aarch64`), forces a set of
"must-have" CONFIGs (squashfs, overlayfs, virtio, devtmpfs, ext4, etc.),
then `make bzImage modules` and `modules_install` into `$LFS`.

For SBC-specific kernels (Raspberry Pi 5 etc.), override
`ORION_KERNEL_DEFCONFIG=bcm2712` before running this stage.

### Stage 06 — bootloader

Builds GRUB 2.12 with the right platform target:
- x86_64: builds both `i386-pc` (BIOS) and `x86_64-efi` (UEFI)
- aarch64: builds `arm64-efi` only

Writes a template `grub.cfg` to `$LFS/boot/grub/grub.cfg` with three
menu entries (normal, recovery, verbose). The actual `grub-install`
(which writes MBR / EFI BootXXXX entry) happens inside the installer
at install time, because we need a real block device.

### Stage 07 — make image

Packages the finished `$LFS` tree into:

1. A rootfs tarball (`out/orion-rootfs-<arch>-<ver>.tar.xz`)
2. A squashfs layer for the live ISO (`rootfs.squashfs`, zstd-compressed)
3. A bootable netinst ISO (hybrid BIOS+UEFI on x86_64, UEFI on aarch64)

### Stage 08 — release artifacts

A standalone script invoked from the Makefile (`make iso`, `make img`)
or from CI. Takes an already-built rootfs tarball and wraps it into
either:

- `Orion-Linux-<ver>-<arch>-netinst.iso` — bootable installer ISO
- `Orion-Linux-<ver>-<arch>.img.zst` — flashable disk image (ARM SBCs)

Both produce a `.sha256` checksum alongside the artifact.

## Build environment

Each stage runs inside a Docker container built from
`images/Dockerfile.<arch>`. The Dockerfile uses Debian 12 slim as the
base (because we need a stable host toolchain to bootstrap the
cross-compiler; nothing from Debian ends up in the final image).

Each stage is a separate `RUN` layer so failures resume cheaply:
rebuilding after a stage-03 fix does not re-run stages 00–02.

For aarch64, the Dockerfile is identical except for the `--platform=linux/arm64`
flag. The host runs `multiarch/qemu-user-static` to register binfmt
handlers so the kernel can exec aarch64 binaries via QEMU.

## Cross-package and cross-arch

A single repo builds both architectures. Where they differ:

| Concern                  | x86_64                              | aarch64                          |
| ------------------------ | ----------------------------------- | -------------------------------- |
| Bootloader               | GRUB i386-pc + x86_64-efi           | GRUB arm64-efi                   |
| Kernel image             | `arch/x86/boot/bzImage`              | `arch/arm64/boot/Image`           |
| Kernel defconfig         | `packages/linux/config-x86_64`      | `packages/linux/config-aarch64`  |
| Min kernel version       | 4.19 (glibc requires)                 | 5.10 (glibc requires)             |
| CI runtime               | ~6–10 hours                         | ~12–20 hours (QEMU emulation)   |
| Live ISO type            | hybrid BIOS + UEFI                  | UEFI only                         |
| SBC support              | n/a                                 | U-Boot at sector 64 (board spec) |

## Filesystem layout on disk (post-install)

```
/
├── boot/
│   ├── efi/                  ← EFI System Partition (FAT32, ~512 MiB)
│   │   └── EFI/BOOT/
│   │       └── bootx64.efi  ← GRUB standalone image
│   ├── grub/
│   │   └── grub.cfg         ← generated by installer
│   ├── vmlinuz              ← symlink to current kernel
│   ├── vmlinuz-6.12.4-orion
│   ├── System.map-6.12.4-orion
│   └── config-6.12.4-orion
├── etc/
│   ├── os-release           ← from config/os-release
│   ├── orion-release
│   ├── fstab                 ← generated by installer
│   ├── hostname
│   ├── locale.conf
│   ├── vconsole.conf
│   ├── motd
│   ├── issue
│   └── orion/
│       └── repo.d/           ← local package repo (copy of packages/)
├── usr/
│   ├── bin/
│   │   ├── orion-pkg        ← the package manager
│   │   ├── orion-installer  ← the TUI installer
│   │   ├── bash
│   │   └── ...
│   ├── lib/
│   │   ├── systemd/
│   │   └── ...
│   └── share/
│       ├── orion/
│       │   ├── rootfs.manifest
│       │   └── de-profiles/
│       │       ├── gnome.list
│       │       ├── kde.list
│       │       └── xfce.list
│       └── doc/orion-pkg/
├── var/
│   ├── orion/
│   │   ├── installed/       ← orion-pkg manifest dir
│   │   ├── cache/            ← orion-pkg built tarballs
│   │   └── sources/         ← fetched source tarballs
│   └── log/
└── lib/
    └── modules/
        └── 6.12.4-orion/    ← kernel modules
```
