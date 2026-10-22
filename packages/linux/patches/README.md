# packages/linux/patches/

Drop any `*.patch` file in this directory and `scripts/05-build-kernel.sh`
will apply it with `patch -p1` before `make bzImage modules`. Patches are
applied in alphabetical order.

## Format

Patches must be in `diff -p1` format (a.k.a. "unified diff with a/ b/
prefixes"), which is what `git format-patch` produces by default.

```
$ cat my-fix.patch
From: You <you@example.com>
Date: Mon, 1 Jan 2026 00:00:00 +0000
Subject: drivers/foo: fix bar when baz

diff --git a/drivers/foo/bar.c b/drivers/foo/bar.c
index abc..def 100644
--- a/drivers/foo/bar.c
+++ b/drivers/foo/bar.c
@@ -10,5 +10,6 @@ int bar(void)
     return 0;
+    if (baz) return -1;
 }
```

## Generating patches from the user's Linux fork

If you maintain custom patches in your fork at
`github.com/likus-69/Orion-linux-v1.1`, you can export them with:

```bash
git clone https://github.com/likus-69/Orion-linux-v1.1.git
cd Orion-linux-v1.1
# Find the commits you want to ship as patches:
git log --oneline v7.3..HEAD -- drivers/foo/
# Export them:
git format-patch v7.3..HEAD -- drivers/foo/ -o /tmp/patches
# Copy them into the Orion-Linux repo:
cp /tmp/patches/*.patch /path/to/Orion-Linux/packages/linux/patches/
```

## Verifying patches still apply

Before pushing a new patch, run:

```bash
cd /home/z/my-project/Orion-Linux
# Inside the Docker build container (after stage 05 clones the kernel):
#   cd /sources/linux-7.3 && patch -p1 --dry-run < /path/to/patch
```

If the dry-run reports failures, the patch needs rebasing against the
current kernel version.

## What this directory currently contains

Nothing — the v0.1 distro ships a vanilla upstream kernel.
