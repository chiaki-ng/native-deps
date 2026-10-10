#!/usr/bin/env bash
# Assemble a per-architecture prefix from the dep pool and package it.
#
#   scripts/package.sh <arch> <pool-dir> <dist-dir>
#
# Produces <dist-dir>/native-deps-<rev>-darwin-<arch>.tar.zst (containing
# prefix/) plus build-<arch>.json describing the build.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: package.sh <arch> <pool-dir> <dist-dir>"
ARCH=$1
POOLDIR=$(cd "$2" && pwd)
DISTDIR=$3
mkdir -p "$DISTDIR"

need jq "brew install jq"
need zstd "brew install zstd"
command -v rsync >/dev/null 2>&1 || die "rsync not found"

shopt -s nullglob
STAGE="$(dirname "$POOLDIR")/prefix"
rm -rf "$STAGE"
mkdir -p "$STAGE"
count=0
for d in "$POOLDIR"/*/; do
  rsync -a --exclude BUILD-INFO "$d" "$STAGE/"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "pool '$POOLDIR' is empty — nothing to package"
rm -rf "$STAGE/share/man" "$STAGE/share/doc"

rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
TARBALL="native-deps-$rev-darwin-$ARCH.tar.zst"
tar -C "$(dirname "$STAGE")" --zstd -cf "$DISTDIR/$TARBALL" prefix
log "packaged $DISTDIR/$TARBALL"

deps_json="[]"
if ls "$POOLDIR"/*/BUILD-INFO >/dev/null 2>&1; then
  deps_json=$(jq -s '.' "$POOLDIR"/*/BUILD-INFO)
fi
jq -n \
  --arg arch "$ARCH" \
  --arg revision "$rev" \
  --arg tarball "$TARBALL" \
  --arg sha256 "$(hash_file "$DISTDIR/$TARBALL")" \
  --arg deployment_target "$(config_get ".config.$PLATFORM.deployment_target")" \
  --argjson deps "$deps_json" \
  '{arch: $arch, revision: $revision, deployment_target: $deployment_target,
    tarball: $tarball, sha256: $sha256, deps: $deps}' \
  >"$DISTDIR/build-$ARCH.json"
