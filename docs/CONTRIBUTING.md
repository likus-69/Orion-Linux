# Contributing

Thanks for your interest in improving Orion Linux! This document covers
the basics. If anything here is unclear, please
[open an issue](https://github.com/likus-69/Orion-Linux/issues/new) and
we'll improve this doc.

## Project structure

Read [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) first — it explains
the build pipeline and how the pieces fit together. The TL;DR:

```
scripts/     — 8-stage build pipeline (00 = host prep, 07 = ISO)
packages/     — per-package build definitions
orion-pkg/    — the package manager
installer/    — TUI installer
images/       — Dockerfiles + entrypoint
.github/      — CI workflows
docs/         — what you're reading
```

## Ways to contribute

| Want to ...                          | Where to start                            |
| ------------------------------------ | ----------------------------------------- |
| Fix a bug in the build                | `scripts/`, then `images/Dockerfile.*`    |
| Add a new package                     | `packages/<name>/`, follow `packages/README.md` |
| Improve `orion-pkg`                   | `orion-pkg/orion-pkg` + `orion-pkg/tests/` |
| Improve the installer                 | `installer/`                               |
| Improve CI                            | `.github/workflows/`                       |
| Improve docs                          | `docs/`, `README.md`, `packages/README.md` |
| Report a bug                          | Use the "Bug report" issue template        |
| Request a feature                    | Use the "Feature request" issue template   |

## Development setup

You don't need to run a full build to contribute. For most work, you
need:

- bash 4.4+ (every distro has this)
- shellcheck (for linting)
- Docker (only if you want to test full builds)

```bash
git clone https://github.com/likus-69/Orion-Linux.git
cd Orion-Linux
make lint        # shellcheck everything
make test        # run orion-pkg smoke test
```

## Code style

### Shell scripts

- Always `set -euo pipefail` at the top.
- Use `[[ ... ]]` not `[ ... ]` for conditions (we're bash, not sh).
- Use `$()` not backticks.
- Quote variables that may contain spaces: `"$foo"`.
- Use `printf` not `echo -e` when you need escapes.
- Functions use `snake_case`. Variables that are exported use
  `ORION_UPPER_CASE`; locals use `snake_case`.
- Always pass `--` before file arguments when calling commands that
  support it (so a filename starting with `-` doesn't become a flag).
- Use `shellcheck -x` (it'll follow our source statements).

The CI lint job runs:

```bash
shellcheck -x -e SC1090,SC1091 \
  scripts/*.sh scripts/lib/*.sh \
  orion-pkg/orion-pkg \
  installer/orion-installer installer/modules/*.sh \
  images/entrypoint.sh
```

### Documentation

- Markdown only (no asciidoc / rST).
- Hard wrap at 80 columns where reasonable. Soft wrap is fine for long
  URLs.
- One sentence per line is **not** required (we're not git projects
  style). Regular paragraphs are fine.

### Package build scripts

- Always `set -euo pipefail` at the top.
- Use `$MAKEFLAGS` instead of hardcoding `-j4` — it's pre-set.
- Use `$DESTDIR` for install paths, never `/` or `$LFS`.
- Strip binaries at the end: `find "$DESTDIR" -type f -executable
  -exec strip --strip-unneeded {} + 2>/dev/null || true`.
- Don't touch `/etc` from the build script — runtime config files go
  into `$DESTDIR/etc/` and the installer + systemd merge them at
  install time.
- Document why a patch exists, if you ship one. A comment at the top
  of the patch file or in `copyright` works.

## Testing

- `make test` runs the orion-pkg smoke test (`orion-pkg/tests/test_basic.sh`).
- `make lint` runs shellcheck.
- Full build tests run in CI (`.github/workflows/build-*.yml`). They
  take hours, so they only run on PRs to main, not on every push to a
  feature branch.

When adding a new package, add a test case under
`orion-pkg/tests/test_<pkg>.sh` that:

1. Creates a tiny mock source tree
2. Builds it via `orion-pkg build`
3. Installs it
4. Verifies the manifest
5. Removes it
6. Asserts the files are gone

See `orion-pkg/tests/test_basic.sh` for the pattern.

## Pull request checklist

Before opening a PR:

- [ ] `make lint` passes
- [ ] `make test` passes
- [ ] If you added a new package, added a test for it
- [ ] If you changed a build stage, ran `make build` locally and got
      a successful ISO out
- [ ] If you changed CI, tested the YAML with
      `yamllint -d relaxed .github/workflows/*.yml`
- [ ] Updated `docs/` if your change is user-visible
- [ ] Bumped the version in `config/orion-release` if appropriate
- [ ] Squashed or rebased your branch on `main` so it tells a clean
      story

## Commit message style

We don't enforce conventional commits yet, but please:

- First line: imperative mood, ≤72 chars, lowercase if it's a small fix
  ("fix: stage 03 stops on missing bc", "add openssl package").
- Body: explain *why*, not *what* (the diff already shows what).
- Reference issues at the end: `Fixes #123.` or `Ref: #123.`

## Branching

- `main` is the integration branch.
- Feature branches: `feature/<name>` or `fix/<name>`.
- Tag releases: `v0.1.0`, `v0.1.1`, etc.

## Licensing

By contributing, you agree that your contributions will be licensed
under the project's MIT license (see `LICENSE`). Code copied from
elsewhere must retain its original copyright notice.

## Code of Conduct

See [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md). Short version: be
excellent to each other. Build breakage is fine — personal attacks are
not.
