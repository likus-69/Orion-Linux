# Orion Linux

> An LFS 12.3-based, general-purpose Linux distribution for x86_64 and aarch64,
> with a custom minimal package manager, systemd init, and a netinst-style
> installer that lets you pick your desktop.

[![Build x86_64](https://github.com/likus-69/Orion-Linux/actions/workflows/build-x86_64.yml/badge.svg)](https://github.com/likus-69/Orion-Linux/actions/workflows/build-x86_64.yml)
[![Build aarch64](https://github.com/likus-69/Orion-Linux/actions/workflows/build-aarch64.yml/badge.svg)](https://github.com/likus-69/Orion-Linux/actions/workflows/build-aarch64.yml)
[![Lint](https://github.com/likus-69/Orion-Linux/actions/workflows/lint.yml/badge.svg)](https://github.com/likus-69/Orion-Linux/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What is Orion Linux?

Orion Linux is a general-purpose Linux distribution for x86_64 and aarch64,
with custom tooling (an in-house package manager and a TUI installer) and
branding layered on top.

**v0.1** (current) ships a bootable CLI ISO built via Debian's `debootstrap`
as a base — this gets us to a working distro fast while the LFS-from-scratch
pipeline matures.

**v0.2+** will progressively replace the Debian base with packages compiled
from upstream source using the LFS 12.3 book. The full LFS-from-scratch
pipeline already exists in `scripts/00-08` but is incomplete (~50 of ~360
packages scaffolded); it's the v0.2+ roadmap.

The project targets two architectures from a single codebase:

- **x86_64** (Intel/AMD 64-bit) — desktops, laptops, servers
- **aarch64** (ARM 64-bit) — Raspberry Pi 4/5, Ampere VMs, Pinebook, etc.

The aarch64 build runs under QEMU user-mode emulation in CI, so it builds on
the same GitHub-hosted x86_64 runners as the x86_64 image. No self-hosted
hardware required.

## Key features

| Feature              | v0.1 (current)                  | v0.2+ (roadmap)                |
| -------------------- | ------------------------------- | ------------------------------ |
| Base                 | Debian 12 (debootstrap minbase) | LFS 12.3 from source           |
| Init system          | systemd                         | systemd                         |
| Package manager      | `orion-pkg` + apt (layered)    | `orion-pkg` only                |
| Default desktop      | None — netinst picks GNOME/KDE/XFCE | (same)                         |
| Bootloader (x86_64)  | GRUB 2 (BIOS + UEFI)            | (same)                         |
| Bootloader (aarch64) | GRUB-EFI + U-Boot fallback      | (same)                         |
| Kernel               | mainline 6.12 LTS (compiled from source) | (same)                |
| Image format         | tarball rootfs + squashfs netinst ISO | (same)                  |

## Repository layout

```
Orion-Linux/
├── .github/workflows/    # CI: build x86_64, build aarch64 (QEMU), lint
├── config/              # os-release, motd, hostname, branding assets
├── docs/                # BUILD, ARCHITECTURE, PACKAGES, INSTALL, CONTRIBUTING
├── scripts/             # 00-08 build stages (LFS pipeline)
├── packages/            # per-package build definitions (build script + sources)
├── orion-pkg/           # custom package manager (this repo's own code)
├── installer/           # TUI installer with DE picker
├── images/              # Dockerfiles for x86_64 and aarch64 build hosts
├── Makefile             # top-level driver: `make build`, `make iso`, ...
└── README.md
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the deep dive.

## Quickstart (build locally, v0.1)

> Requirements: Docker 24+, ~10 GB free disk (vs 50+ for LFS), x86_64 Linux host.
> aarch64 builds work too — QEMU emulation is wired in automatically.

```bash
git clone https://github.com/likus-69/Orion-Linux.git
cd Orion-Linux

# v0.1 fast-path: build the rootfs + ISO (~20 min)
make build-quick

# Or target a specific arch
make build-quick ARCH=aarch64

# The v0.2+ LFS-from-scratch path (slow, incomplete):
make build          # ~6-10 hours, may fail on missing packages

# Inspect what each target does
make help
```

The v0.1 bootstrap path takes ~20 minutes on x86_64 (~30 min for aarch64
under QEMU). The v0.2+ LFS path takes 6–10 hours on x86_64 and 12–20 hours
for aarch64 under QEMU; each stage is a cached Docker layer so re-runs
after a fix are cheap.

See [docs/BUILD.md](docs/BUILD.md) for the stage-by-stage breakdown.

## Quickstart (install from a release ISO)

1. Download the latest netinst ISO from the
   [Releases page](https://github.com/likus-69/Orion-Linux/releases).
2. Flash to USB: `dd if=Orion-Linux-*.iso of=/dev/sdX bs=4M status=progress`
3. Boot the USB, log in as `root` (no password), run:
   ```bash
   orion-installer
   ```
4. The installer walks you through disk partitioning, base system install, and
   the desktop environment picker. See [docs/INSTALL.md](docs/INSTALL.md) for
   the full walkthrough.

## Building your first custom package

`orion-pkg` is the in-tree package manager. A package is just a directory under
`packages/<name>/` with at least a `build` script and a `version` file:

```
packages/hello/
├── version     # "1.0.0"
├── sources     # URLs or local paths to fetch
├── checksums   # sha256 sums, one per source
├── depends     # newline-separated runtime deps (optional)
└── build       # bash script that ./configure && make && make install
```

Build and install it into your current rootfs:

```bash
orion-pkg build hello
orion-pkg install hello
orion-pkg list            # see what's installed
orion-pkg remove hello    # uninstall
```

See [docs/PACKAGES.md](docs/PACKAGES.md) for the full reference, and
`packages/` for real examples (`bash`, `binutils`, `gcc`, `glibc`, `linux`,
`systemd`, `grub`, etc.).

## Status

**v0.1** (in-progress): Debian-bootstrap path → bootable CLI ISO. CI builds work end-to-end via `make build-quick`; an actual bootable ISO is the immediate next milestone.

**v0.2+** (roadmap): LFS-from-scratch pipeline (scripts/00-08) is scaffolded but incomplete (~50 of ~360 packages). Each LFS package will replace the corresponding Debian binary, one at a time, until the rootfs is 100% from-source.

Roadmap lives in [the Projects tab](https://github.com/likus-69/Orion-Linux/projects).
Bug reports and PRs welcome — see [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE) for the full text. Individual package build scripts
under `packages/` remain under the license of their upstream source — check
each `packages/<name>/copyright` file.
