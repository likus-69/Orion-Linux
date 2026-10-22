#!/usr/bin/env bash
# orion-pkg/tests/test_basic.sh
#
# Smoke test: build, install, list, verify, which, remove a trivial package
# in a temp chroot. Runs in <5 seconds on a modern host.

set -euo pipefail

ORION_PKG="$(dirname "$0")/../orion-pkg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export ORION_ROOT="$WORK"
export ORION_REPO="$WORK/repo.d"
export ORION_DB="$WORK/db"
export ORION_CACHE="$WORK/cache"
export ORION_DOWNLOAD="$WORK/sources"
mkdir -p "$ORION_REPO" "$ORION_DB" "$ORION_CACHE" "$ORION_DOWNLOAD"

# --- 1. Define a 'hello' package -------------------------------------------
pkg="$ORION_REPO/hello"
mkdir -p "$pkg"
cat > "$pkg/version" <<EOF
1.0.0
EOF

# Use a tiny C program as the "source" instead of downloading anything.
# Write it directly via file:// in sources.
src="$WORK/hello-src"
mkdir -p "$src"
cat > "$src/hello.c" <<EOF
#include <stdio.h>
int main(void){ puts("hello from orion-pkg test"); return 0; }
EOF
tar -czf "$ORION_DOWNLOAD/hello-1.0.0.tar.gz" -C "$WORK" hello-src
sum=$(sha256sum "$ORION_DOWNLOAD/hello-1.0.0.tar.gz" | awk '{print $1}')

cat > "$pkg/sources" <<EOF
file://$ORION_DOWNLOAD/hello-1.0.0.tar.gz
EOF
echo "$sum" > "$pkg/checksums"
: > "$pkg/depends"
cat > "$pkg/copyright" <<EOF
MIT
EOF
cat > "$pkg/build" <<'EOF'
set -euo pipefail
# orion-pkg extracts the source tarball into the CWD with --strip-components=1,
# so hello.c is already in the current directory.
mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/doc/hello"
gcc -o "$DESTDIR/usr/bin/hello" hello.c
echo "hello 1.0.0 — orion-pkg test" > "$DESTDIR/usr/share/doc/hello/README"
EOF

# --- 2. Run commands -------------------------------------------------------
echo "TEST: build"
"$ORION_PKG" build hello

echo "TEST: install"
"$ORION_PKG" install -y hello

# Pipe through `cat` so grep -q closing the pipe doesn't SIGPIPE the upstream
# (which under `set -o pipefail` would abort this script).
echo "TEST: list"
"$ORION_PKG" list > /tmp/orion-list.txt
grep -q hello /tmp/orion-list.txt

echo "TEST: list --all"
"$ORION_PKG" list --all > /tmp/orion-list-all.txt
grep -q hello /tmp/orion-list-all.txt

echo "TEST: info"
"$ORION_PKG" info hello > /tmp/orion-info.txt
grep -q 'installed' /tmp/orion-info.txt

echo "TEST: which"
"$ORION_PKG" which "$WORK/usr/bin/hello" > /tmp/orion-which.txt
grep -q hello /tmp/orion-which.txt

echo "TEST: verify"
"$ORION_PKG" verify hello

echo "TEST: remove"
"$ORION_PKG" remove -y hello
"$ORION_PKG" list > /tmp/orion-list-after.txt
if grep -q '^hello' /tmp/orion-list-after.txt; then
  echo "FAIL: hello still listed after remove" >&2
  exit 1
fi

echo ""
echo "All orion-pkg basic tests passed."
