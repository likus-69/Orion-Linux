# Build guide

This document describes how to build Orion Linux from scratch, both via
the Makefile (recommended) and stage-by-stage (for debugging).

## Prerequisites

### Hardware

- A modern Linux host with **at least 8 GiB RAM** and **50 GiB free disk**
  for a single arch build. aarch64+QEMU builds want 16 GiB RAM.
- x86_64 host CPU (you can cross-build aarch64 from x86_64). Native
  aarch64 hardware (Pi 5, Ampere VM) also works and is faster than QEMU.

### Software (host)

| Tool                          | Min version | Purpose                       |
| ----------------------------- | ----------- | ----------------------------- |
| Docker Engine                 | 24.0+       | Container builds              |
| bash                          | 4.4+        | Build scripts                 |
| git                           | any recent  | Tagging releases              |
| qemu-user-static (for aarch64)| any recent  | binfmt emulation              |
| xorriso                       | any recent  | ISO assembly                  |
| mtools, dosfstools            | any recent  | FAT image creation             |

On Debian/Ubuntu:

```bash
sudo apt-get install -y docker.io bash git \
  qemu-user-static qemu-utils ovmf xorriso mtools dosfstools squashfs-tools \
  shellcheck
```

## Quick build

From the repo root:

```bash
# x86_64 (default — matches your host arch on most machines)
make build

# aarch64 (will run via QEMU emulation on an x86_64 host)
make build ARCH=aarch64
```

The first build takes ~6–10 hours on x86_64 and ~12–20 hours on aarch64
under QEMU. Subsequent builds reuse Docker layer cache and only re-run
the stage that changed.

## What `make build` actually runs

Under the hood, the Makefile runs:

```bash
docker build \
  --build-arg ARCH=x86_64 \
  --build-arg VERSION=$(git describe --tags --always --dirty) \
  --file images/Dockerfile.x86_64 \
  --tag orion-linux:x86_64-<version> \
  .

# Then extracts the rootfs tarball from the image:
container_id=$(docker create orion-linux:x86_64-<version>)
docker cp $container_id:/out/orion-rootfs-x86_64-<version>.tar.xz out/
docker rm $container_id
```

Each `RUN` line in the Dockerfile is one build stage (00–07). If a stage
fails, fix the script and re-run `make build` — Docker will resume from
the last successful layer.

## Stage-by-stage build (debugging)

For debugging a specific stage, you can run inside a shell in the
half-built image:

```bash
# Start a shell in the half-built image (resume from the layer cache)
docker run --rm -it orion-linux:x86_64-<version> \
  /usr/src/orion/images/entrypoint.sh bash

# Or just re-run a single stage:
docker run --rm -it \
  -v $PWD:/work -w /work \
  -v /var/run/docker.sock:/var/run/docker.sock \
  orion-linux:x86_64-<version> \
  /usr/src/orion/images/entrypoint.sh 03-lfs-system
```

For an entirely local (non-Docker) build, you can run the scripts
directly — but you must do the host prep yourself:

```bash
# Install host deps
sudo apt-get install -y bash gcc g++ make patch bison flex texinfo \
  gperf gettext curl tar xz-utils bzip2 libgmp-dev libmpfr-dev \
  libmpc-dev libelf-dev libssl-dev zlib1g-dev libzstd-dev libcap-dev \
  libattr1-dev libacl1-dev libseccomp-dev

# Run stages in order
sudo bash scripts/00-host-prepare.sh
sudo -u orionlfs bash scripts/01-build-cross-toolchain.sh
sudo -u orionlfs bash scripts/02-build-temp-tools.sh
sudo bash scripts/03-build-lfs-system.sh
sudo bash scripts/04-config-system.sh
sudo bash scripts/05-build-kernel.sh
sudo bash scripts/06-build-bootloader.sh
sudo bash scripts/07-make-image.sh x86_64 dev /out /mnt/orion
```

The non-Docker path is faster but more fragile — Docker isolates you
from host toolchain drift.

## Resuming a failed build

Each stage writes a log to `build/logs/<stage>.log`. The script aborts
at the first command that fails (`set -e` is on by default).

To resume:

1. Read the log: `less build/logs/<stage>.log`
2. Fix the offending package script under `packages/<name>/build`
3. Re-run only that stage:

   ```bash
   docker run --rm -it \
     -v $PWD:/work -w /work \
     orion-linux:x86_64-<version> \
     /usr/src/orion/images/entrypoint.sh <stage-name>
   ```

4. Or, if you've changed the script file itself (which invalidates
   Docker cache), re-run `make build` — Docker will re-execute every
   layer after the changed one.

## Building the bootable ISO

Once `make build` has produced `out/orion-rootfs-*.tar.xz`, run:

```bash
make iso ARCH=x86_64
# or
make iso ARCH=aarch64
```

This runs `scripts/08-release-artifacts.sh iso`, which:

1. Extracts the rootfs tarball into a temp dir
2. Compresses the extracted tree into a squashfs (zstd level 19)
3. Copies the kernel + System.map into a fresh ISO staging tree
4. Builds a grub EFI standalone image (x86_64 or arm64)
5. Assembles a hybrid ISO with xorriso (BIOS + UEFI on x86_64, UEFI on
   aarch64)

Output: `out/Orion-Linux-<version>-<arch>-netinst.iso`.

## Building the flashable disk image (ARM SBCs)

For a Raspberry Pi or other ARM SBCs:

```bash
make img ARCH=aarch64 \
  # If your board needs a specific U-Boot binary at sector 64:
  ORION_UBOOT_BIN=/usr/lib/u-boot/rpi_5/u-boot.bin
```

This produces `out/Orion-Linux-<version>-aarch64.img.zst` (a 4 GiB image
with GPT partition table, ext4 root, FAT32 ESP at /boot/efi).

Flash to your SD/eMMC with:

```bash
zstd -d Orion-Linux-*.img.zst -o orion.img
sudo dd if=orion.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## Release process

1. Update `config/os-release` and `config/orion-release` with the new
   version string.
2. Commit everything, push to main.
3. Tag a release:
   ```bash
   make release VERSION=0.1.0
   ```
   This runs `git tag -a v0.1.0 -m "Orion Linux 0.1.0"` and pushes the tag.
4. Watch CI on https://github.com/likus-69/Orion-Linux/actions
   - The x86_64 build triggers `build-x86_64.yml`
   - The aarch64 build triggers `build-aarch64.yml`
   - Both produce a draft GitHub Release with all artifacts attached.
5. Manually review the draft release, write release notes, then publish.

## Troubleshooting

### "out of disk space"

The Docker cache grows fast. Clean it:

```bash
make distclean     # removes docker build cache + local artifacts
docker system prune -a --volumes
```

### "qemu: Unsupported syscall"

The QEMU user-mode emulator doesn't support every syscall Linux offers.
Common offenders: `io_uring`, `clone3` args newer than the QEMU release.

Workarounds:

- Pin glibc to a version that doesn't use the offending syscall
- Upgrade qemu-user-static on the host: `sudo apt-get install --only-upgrade qemu-user-static`
- Drop the QEMU path; cross-compile instead (more setup, much faster)

### Stage 01 fails at gcc pass 1

Most common cause: missing libmpc/libmpfr/libisl headers on the host.
Install with `sudo apt-get install libgmp-dev libmpfr-dev libmpc-dev
libisl-dev` and re-run.

### Stage 03 fails at "systemd"

Systemd 256 wants meson ≥ 1.3 and ninja ≥ 1.11. If the build host
(Debian 12) ships older versions, build them first:

```bash
# Inside the Docker container:
pip3 install meson==1.3.2
curl -L https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip -o ninja.zip
unzip ninja.zip && install -m755 ninja /usr/bin/
```

The Dockerfile already installs these via apt; this only matters for
local non-Docker builds.

### Stage 06 fails at "grub-install: cannot find EFI directory"

The target disk has no ESP mounted at `/boot/efi`. This happens when
the installer skips the EFI step (older install) or when building the
disk image without an ESP. Fix by setting
`installer_module_partition` to create a 512 MiB ESP.

## What to do when a build is "stuck"

Long-running compiles look identical to hangs. Sanity-check with:

```bash
# Inside the container:
ps -ef | grep -E "(make|gcc|cc1|ld)" | head
# Outside:
docker stats --no-stream
```

If CPU is at 100%, the build is running. If CPU is idle for >5 min, the
build is wedged — abort and restart.
