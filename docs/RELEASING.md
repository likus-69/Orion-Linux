# Release process

This is a checklist for cutting a new Orion Linux release. Maintainers
should follow it end-to-end before tagging.

## Pre-release checklist

1. **Update version strings**:
   ```bash
   sed -i 's/VERSION=.*/VERSION="0.1.0 (LFS 12.3 base)"/' config/os-release
   sed -i 's/^Orion Linux.*/Orion Linux 0.1.0 "heracles"  (LFS 12.3 base.../' config/orion-release
   ```
   Match the version in `Makefile` (`VERSION ?= $(shell git describe ...)`)
   and bump the build date in `config/orion-release`.

2. **Check that main is green**: visit
   https://github.com/likus-69/Orion-Linux/actions and confirm the
   latest commit on `main` has both `Build x86_64` and `Build aarch64`
   passing.

3. **Update changelog**: append to `docs/CHANGELOG.md` (TBD) or just
   write the release notes inline — `softprops/action-gh-release`
   generates a draft from commit messages.

4. **Bump the build ID**: edit `BUILD_ID` in `config/os-release` to
   today's date in `YYYYMMDD` form.

## Tagging the release

```bash
make release VERSION=0.1.0
```

This runs:

```bash
git tag -a v0.1.0 -m "Orion Linux 0.1.0"
git push origin v0.1.0
```

## What happens next

The push of the `v*` tag triggers both CI workflows:

- `.github/workflows/build-x86_64.yml` — runs on the next available
  ubuntu-22.04 runner, ~6–10 hours
- `.github/workflows/build-aarch64.yml` — runs on the next available
  ubuntu-22.04 runner, ~12–20 hours under QEMU

Both workflows:

1. Check out the tag
2. Build the Docker image (with caching)
3. Extract the rootfs tarball
4. Build the netinst ISO (and a flashable `.img` for aarch64)
5. Compute sha256 checksums
6. Create a **draft** GitHub Release with all artifacts attached

The release is draft so you can review it before users see it.

## Post-build

1. **Wait for both workflows to finish**. Watch them at
   https://github.com/likus-69/Orion-Linux/actions
2. **Review the draft release** at
   https://github.com/likus-69/Orion-Linux/releases
3. **Edit the release notes** — add the changelog, screenshot of the
   installer, link to the architecture diagram.
4. **Verify the checksums** by downloading one artifact on a
   different machine and running `sha256sum -c`.
5. **Publish the release** (uncheck "Set as a draft").
6. **Tweet / announce** — post in the LFS community matrix room, on
   r/linuxfromscratch, and in any Orion Linux socials.

## What if the build fails?

If CI fails:

1. **Don't delete the tag**. Leave it as a record of the attempt.
2. Read the failing stage's log (`scripts/<stage>.sh` produced it).
3. Push a fix commit on `main`, then re-tag with a `.1` suffix:
   ```bash
   git tag -d v0.1.0      # delete the broken tag locally
   git push origin :refs/tags/v0.1.0   # delete on the remote
   # ... fix ...
   git tag -a v0.1.0 -m "Orion Linux 0.1.0"
   git push origin v0.1.0
   ```

## What about pre-releases?

Pre-releases use a `-rcN` suffix:

```bash
git tag -a v0.1.0-rc1 -m "Orion Linux 0.1.0-rc1"
git push origin v0.1.0-rc1
```

The GitHub release should be marked as a **pre-release** (the workflow
sets `draft: true` but doesn't auto-mark prereleases; you'll need to
do that manually after CI finishes).

## Yank a release

If a release has a critical bug:

1. Go to the release page on GitHub
2. Edit the release → click **Set as a draft release**
3. Update the release notes to say "YANKED — please use vX.Y.Z-1"
4. Open an issue describing what broke

Don't delete the tag — users who already installed it need a record of
what they got.
