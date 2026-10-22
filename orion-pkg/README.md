# orion-pkg — Orion Linux package manager

`orion-pkg` is a minimal, dependency-light package manager for Orion Linux.
It is roughly 600 lines of pure bash and requires only coreutils, `tar`,
`sha256sum`, `curl`, and optionally `fakeroot`/`unshare` for sandboxed builds.

## Why a custom package manager?

LFS 12.3 ships with **no package manager** — by design. The book argues that
the user should pick one. Orion Linux picks a small, readable, audit-friendly
package manager rather than wiring in pacman/apt/dpkg, because:

1. The whole codebase fits in a single terminal screen. Anyone can audit it.
2. Package definitions are 5–10 lines of bash per file. Easy to write,
   easy to review, easy to fork.
3. No metadata format to learn. A package is a directory with files in it.
4. The build sandbox uses standard `unshare -r` (or `fakeroot`) — no chroot
   setup required.

If you'd rather use a battle-tested package manager, see
[docs/PACKAGES.md](../docs/PACKAGES.md) for the install-time option to swap
`orion-pkg` for `pacman` or `dpkg`.

## Quick start

```bash
# Build the 'hello' package from packages/hello/
orion-pkg build hello

# Install it
orion-pkg install hello

# See what's installed
orion-pkg list

# Find which package owns /usr/bin/hello
orion-pkg which /usr/bin/hello

# Remove it
orion-pkg remove hello
```

## Package layout

Each package lives in `$ORION_REPO/<name>/`. By default, `$ORION_REPO` is
`/etc/orion/repo.d`. A package directory contains:

| File         | Required | Description                                            |
| ------------ | -------- | ------------------------------------------------------ |
| `version`    | yes      | Single line, the version string                         |
| `sources`    | yes (usually) | One URL per line, can be `file://` for local sources |
| `checksums`  | yes (usually) | One SHA-256 per line, matching `sources` order      |
| `depends`    | no       | One package name per line (runtime deps)                |
| `build`      | yes      | Bash script; runs in source dir, installs to `$DESTDIR` |
| `copyright`  | no       | License info, one line per file                         |

### Example package

```
packages/hello/
├── version     → "1.0.0"
├── sources     → "https://ftp.gnu.org/gnu/hello/hello-1.0.0.tar.gz"
├── checksums   → "<sha256 of the tarball>"
├── depends     → (empty)
├── copyright   → "GPL-3.0-or-later"
└── build       → see below
```

`build` script:

```bash
#!/usr/bin/env bash
# Runs in the extracted source directory.
# $DESTDIR points to where you must install files (the package payload).
# $PKG, $VERSION_PKG are also available.
set -e
./configure --prefix=/usr
make "$MAKEFLAGS"
make DESTDIR="$DESTDIR" install
# Strip binaries
find "$DESTDIR" -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
```

## Commands

| Command                 | Description                                              |
| ----------------------- | -------------------------------------------------------- |
| `build <pkg>`           | Fetch, verify, build, and tar up a package                |
| `install <pkg...>`      | Install one or more built packages (resolves deps first)  |
| `remove  <pkg...>`      | Remove installed packages, walking the manifest backwards |
| `list [--all]`          | List installed packages, or all available when `--all`   |
| `info <pkg>`            | Show metadata of an installed or available package        |
| `search <regex>`        | List available packages whose names match                 |
| `update`                | Refresh the repo index (placeholder for future remote sync)|
| `upgrade`               | Rebuild + reinstall any package with a bumped version     |
| `verify <pkg>`           | Check that all files listed in the manifest exist         |
| `which <file>`          | Show which installed package owns a given path           |

## Environment variables

| Variable             | Default                  | Description                          |
| -------------------- | ------------------------ | ------------------------------------ |
| `ORION_ROOT`         | `""` (empty = `/`)        | Chroot prefix for all paths           |
| `ORION_DB`           | `/var/orion/installed`   | Where manifests live                  |
| `ORION_CACHE`        | `/var/orion/cache`       | Where built tarballs live             |
| `ORION_REPO`         | `/etc/orion/repo.d`       | Local repo dir                        |
| `ORION_DOWNLOAD`     | `/var/orion/sources`     | Where fetched sources are cached      |
| `ORION_BUILD_USER`   | `orionlfs`                | User to drop privileges to (unused yet) |
| `ORION_JOBS`         | `nproc`                   | Parallelism for builds                |

## Limitations

This is v0.1. The following are **not** implemented yet:

- Remote repo sync (currently a local-only repo)
- Signed packages (no GPG verification)
- Delta / binary diffs
- File triggers (post-install scripts per file)
- Hooks (pre/post install/remove)
- Split packages (`-dev`, `-doc`, `-libs`)
- Multi-arch repo (one tree per arch)

These are tracked in the [Projects board](https://github.com/likus-69/Orion-Linux/projects).

## Testing

```bash
bash orion-pkg/tests/test_basic.sh
```

The test suite creates a temp `$ORION_ROOT`, builds a trivial `hello` package,
installs it, verifies, lists, and removes it. It runs in <5 seconds and
requires only `bash`, `tar`, and `gcc` on the host.

## License

MIT, same as the rest of Orion Linux.
