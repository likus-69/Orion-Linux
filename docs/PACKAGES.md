# Package manager guide

`orion-pkg` is the Orion Linux package manager. This document is the
complete reference; for a quick start, see
[`orion-pkg/README.md`](../orion-pkg/README.md).

## Package format

A package is a directory under `$ORION_REPO` (default: `/etc/orion/repo.d`).
Each directory contains:

| File         | Required | Purpose                                              |
| ------------ | -------- | --------------------------------------------------- |
| `version`    | yes      | Version string, single line                          |
| `sources`    | yes      | Newline-separated URLs (`https://`, `ftp://`, `file://`) |
| `checksums`  | yes      | One SHA-256 per line, matching `sources` order      |
| `build`      | yes      | Bash script; sourced in the extracted source tree   |
| `depends`    | no       | Runtime deps, one per line                          |
| `copyright`  | no       | License info                                        |
| `patches/`   | no       | `*.patch` files auto-applied with `-p1` before build |

## Build script environment

When `build` is sourced, the following variables are pre-set:

| Variable       | Meaning                                                |
| -------------- | ------------------------------------------------------ |
| `$DESTDIR`     | Empty directory where the package payload must land   |
| `$PKG`         | The package name                                       |
| `$VERSION_PKG` | The package version                                    |
| `$MAKEFLAGS`   | Pre-set to `-j<nproc>`                                 |
| `$ORION_JOBS`  | Same as nproc                                           |
| `$ORION_ARCH`  | Build architecture                                     |
| `$LFS_TGT`     | Target triplet, e.g. `x86_64-orion-linux-gnu`         |
| `$LFS`         | Root of the target system (when building inside LFS)   |

The script runs in the extracted source tree (the first `tar` member of
the first `sources` URL, after `--strip-components=1`).

The build is sandboxed via `unshare -r` (rootless namespace) when
available, falling back to `fakeroot`. This means the build script can
install files to absolute paths inside `$DESTDIR` (e.g.
`/usr/bin/foo`) without actually touching the host.

## Build variants

Many LFS packages are built more than once — once in the temp toolchain,
once natively inside the chroot, and (for some) once again in the final
stage. The `build` script accepts a `variant=` or `pass=` argument:

```bash
# Temp toolchain bash (stage 02)
source packages/bash/build variant=temp

# Native bash (stage 03)
source packages/bash/build variant=final

# binutils pass 1, 2, or 3
source packages/binutils/build pass=1
source packages/binutils/build pass=2
source packages/binutils/build pass=3
```

When `orion-pkg build` runs standalone (post-install), it always uses
the `final` variant by default. Pass `variant=<x>` as a build arg to
override.

## Dependencies

A package's `depends` file is consulted at install time only. Build
dependencies are not declared — they're the responsibility of the build
environment (the Dockerfile ensures they exist).

To add a runtime dependency:

```
$ cat packages/foo/depends
glibc
openssl
libxml2
```

When `orion-pkg install foo` runs, it walks each `dep` and installs it
recursively (skipping already-installed packages).

## Multi-arch builds

`orion-pkg` itself is arch-agnostic; packages are built for the host's
`uname -m`. To build for a foreign arch:

```bash
# Build an aarch64 package on an x86_64 host (requires qemu-user-static)
ORION_ARCH=aarch64 \
  LFS_TGT=aarch64-orion-linux-gnu \
  PATH=/tools/aarch64/bin:$PATH \
  orion-pkg build <pkg>
```

For the full cross-arch pipeline, use the build images:
`make build ARCH=aarch64`.

## Repository layout

A package repo is just a directory of package directories. To share a
repo, you can:

1. **Git**: clone `https://github.com/likus-69/Orion-Linux`, point
   `ORION_REPO` at `Orion-Linux/packages/`.
2. **HTTP**: serve the directory over HTTP; future versions will
   support `update` to fetch a repo index.
3. **Local file**: drop new package dirs into `/etc/orion/repo.d/local/`.

## Local overrides

To add a custom package without modifying the upstream repo:

```bash
sudo mkdir -p /etc/orion/repo.d/local/myapp
sudo $EDITOR /etc/orion/repo.d/local/myapp/{version,sources,checksums,build}
sudo orion-pkg build myapp
sudo orion-pkg install myapp
```

`orion-pkg list --all` will now include `myapp`.

## Signing (future)

v0.1 of `orion-pkg` does NOT verify signatures. The roadmap is:

- v0.2: per-package GPG signatures in `signature.asc` next to `checksums`
- v0.3: repository-level GPG keys, verified at `update` time
- v0.4: minisign for smaller signatures, faster verify

For now: only install packages from repos you trust.

## Limitations (v0.1)

- No delta / binary diffs (every rebuild ships the full package)
- No split packages (`-dev`, `-doc`, `-libs`)
- No file triggers (no `usr/lib/tmpfiles.d/foo.conf` is auto-applied)
- No hooks (no `preinst`, `postinst` scripts)
- No version comparison logic (you must uninstall + reinstall to upgrade)
- No "provides"/"conflicts" relations

These will land in v0.2+. Tracked at
https://github.com/likus-69/Orion-Linux/projects

## Writing your first package — worked example

Goal: package `htop` from source.

```bash
mkdir -p /etc/orion/repo.d/local/htop
cd       /etc/orion/repo.d/local/htop

# 1. version
echo "3.3.0" > version

# 2. sources + checksums
echo "https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz" > sources
curl -sL "$(cat sources)" | sha256sum | awk '{print $1}' > checksums

# 3. depends
cat > depends <<EOF
glibc
ncurses
EOF

# 4. copyright
echo "GPL-2.0-or-later" > copyright

# 5. build script
cat > build <<'EOF'
set -euo pipefail
./configure --prefix=/usr --enable-cgroup --enable-delayacct
make "$MAKEFLAGS"
make install DESTDIR="$DESTDIR"
# Strip
find "$DESTDIR" -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
# bash completion
install -Dm0644 /dev/stdin "$DESTDIR/usr/share/bash-completion/completions/htop" <<'BC'
complete -c htop
BC
EOF

# 6. build + install
orion-pkg build htop
sudo orion-pkg install htop
```

That's a complete, real-world package in ~30 lines.

## Testing

```bash
bash orion-pkg/tests/test_basic.sh
```

This builds a trivial `hello` package in a temp chroot, installs it,
verifies, lists, and removes it. <5 seconds, requires only `bash`,
`gcc`, and `tar`.
