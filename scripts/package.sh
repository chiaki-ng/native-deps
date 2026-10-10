#!/usr/bin/env bash
# Package each built dependency as its own archive.
#
#   scripts/package.sh <arch> <pool-dir> <dist-dir>
#
# For every deps/<name>/<platform>.toml in the pool, produces
#   <dist-dir>/<name>-<version>-darwin-<arch>.tar.gz  (containing <name>/,
#   i.e. that dependency's include/ + lib/ + bin/)
# plus build-<arch>.json describing the build.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: package.sh <arch> <pool-dir> <dist-dir>"
ARCH=$1
POOLDIR=$(cd "$2" && pwd)
DISTDIR=$3
mkdir -p "$DISTDIR"

need jq "brew install jq"
command -v rsync >/dev/null 2>&1 || die "rsync not found"
shopt -s nullglob

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

count=0
for d in "$POOLDIR"/*/; do
  name=$(basename "$d")
  info="$d/BUILD-INFO"
  [ -f "$info" ] || continue
  version=$(jq -r '.version' "$info")

  rsync -a --exclude BUILD-INFO "${d%/}" "$STAGE/"
  rm -rf "$STAGE/$name/share/man" "$STAGE/$name/share/doc"

  tarball="$name-$version-darwin-$ARCH.tar.gz"
  tar -C "$STAGE" -czf "$DISTDIR/$tarball" "$name"
  log "packaged $DISTDIR/$tarball"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "pool '$POOLDIR' is empty — nothing to package"

rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
deps_json="[]"
if ls "$POOLDIR"/*/BUILD-INFO >/dev/null 2>&1; then
  deps_json=$(jq -s '.' "$POOLDIR"/*/BUILD-INFO)
fi
jq -n \
  --arg arch "$ARCH" \
  --arg revision "$rev" \
  --arg deployment_target "$(config_get '.config.deployment_target')" \
  --argjson deps "$deps_json" \
  '{arch: $arch, revision: $revision, deployment_target: $deployment_target, deps: $deps}' \
  >"$DISTDIR/build-$ARCH.json"
