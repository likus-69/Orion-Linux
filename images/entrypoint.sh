#!/usr/bin/env bash
# images/entrypoint.sh
#
# Container entrypoint used when the build image is run directly (not via
# `docker build`). Useful for iterating on a broken stage without
# re-running the entire build.
#
# Usage:
#   docker run --rm -v "$PWD":/work -w /work orion-linux:latest \
#     /usr/src/orion/images/entrypoint.sh [stage-name]
#
# Examples:
#   ./entrypoint.sh                   # run all stages
#   ./entrypoint.sh 03-lfs-system     # re-run only stage 03
#   ./entrypoint.sh bash              # open a shell in the build env

set -euo pipefail

REPO=/usr/src/orion
SCRIPTS=$REPO/scripts

case "${1:-all}" in
  all)
    for s in "$SCRIPTS"/0[0-9]-*.sh; do
      echo ""
      echo "================================================================"
      echo "  $(basename "$s")"
      echo "================================================================"
      bash -ex "$s" || { echo "stage failed: $(basename "$s")" >&2; exit 1; }
    done
    ;;
  bash|sh)
    exec /bin/bash
    ;;
  *)
    # Single stage
    s="$SCRIPTS/$1.sh"
    [[ "$1" == 0* ]] && s="$SCRIPTS/$1.sh"
    [[ -f "$s" ]] || { echo "stage not found: $1" >&2; exit 2; }
    exec bash -ex "$s"
    ;;
esac
