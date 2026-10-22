# packages/ — Orion Linux package definitions

This directory holds the source definitions for every package that
`orion-pkg` can build and install. Each subdirectory is one package.

## Layout

```
packages/<pkg>/
├── version       # single line, the version string
├── sources       # newline-separated URLs (or file:// paths)
├── checksums     # sha256 per line, matching sources order
├── depends       # runtime deps, one per line (optional)
├── build         # bash script: ./configure && make && make DESTDIR=$DESTDIR install
├── copyright     # license info (optional)
└── patches/      # any .patch files to apply before build (optional)
```

## Conventions

1. **Build script environment**: when `build` is sourced, the working
   directory is the extracted source tree. `$DESTDIR` points to a fresh
   empty dir where the package payload must be installed. `$PKG`,
   `$VERSION_PKG`, `$MAKEFLAGS`, `$ORION_JOBS` are also exported.

2. **Patches**: any `*.patch` file in `patches/` is applied with `-p1`
   before the build runs (handled by the build pipeline, not by you).

3. **Variants**: many packages are built more than once during the LFS
   pipeline (e.g. `bash` is built as a temp tool in stage 02, then
   rebuilt natively in stage 03). The build script accepts a `variant=`
   argument:

   ```bash
   source packages/bash/build variant=temp     # stage 02
   source packages/bash/build variant=native    # stage 03
   source packages/bash/build variant=final     # stage 03 final
   ```

   See `bash/build` for an example.

4. **Frozen versions**: the canonical versions for LFS 12.3 are pinned
   in `scripts/lib/common.sh` in the `LFS_VERSIONS` associative array.
   The `version` file in each package directory should match.

## Included packages

The packages currently scaffolded:

| Package       | Build script | Notes                                            |
| ------------- | ------------ | ------------------------------------------------ |
| `binutils`    | `build`      | Pass 1, 2, 3 via `pass=N` argument               |
| `gcc`         | `build`      | Pass 1, 2, 3 + libstdc++ via `pass=` / `target=` |
| `glibc`       | `build`      | Target libc; needs linux headers                 |
| `linux`       | `build`      | Kernel; `target=headers` for headers, else full   |
| `bash`        | `build`      | `variant=temp\|native\|final`                    |
| `coreutils`   | `build`      | `variant=temp\|final`                            |
| `systemd`     | `build`      | Init; needs dbus, libseccomp                      |
| `grub`        | `build`      | Bootloader (BIOS + EFI)                          |
| `util-linux`  | `build`      | `variant=final`                                  |
| `openssl`     | `build`      | TLS / crypto                                      |

To add a new package: `mkdir packages/<name>` and copy the layout from
an existing one. `bash/build` is a good template — small and easy to read.

## Repo layout for distribution

`orion-pkg` looks for packages in `$ORION_REPO` (default
`/etc/orion/repo.d`). When the build pipeline creates the rootfs tarball,
it copies this directory into the rootfs at that path, so `orion-pkg
list --all` works on the installed system out of the box.
